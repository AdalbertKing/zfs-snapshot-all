#!/bin/bash
# alert-digest.sh v37 -- THE only mail this host sends about backups. Once a day
# it summarises everything notify-fail.sh (ALERT) and notify-warn.sh (WARN)
# queued since the last run, in ONE message, and is completely silent on a day
# with nothing to report.
#
# One mail per host per day is the whole point: at fleet scale the previous
# design (immediate mail per finding, rate-limited per message text) produced
# mail proportional to the number of distinct findings, so two jobs failing in
# the same cron tick sent two mails in the same second. An operator who filters
# the alerting away is worse off than one who reads a single daily summary.
#
# A silent day means "nothing was queued" -- it does NOT prove the host is
# healthy, since a dead cron would also be silent. That gap is closed once a
# week rather than daily: see the heartbeat below. A daily "all OK" from every
# host is exactly the noise this design replaced, but a weekly one is cheap and
# is the only thing that distinguishes a quiet host from a mute one.
# Config file and env precedence live in alert-env.sh, installed beside this
# script by deploy.sh (root's /root/scripts, an account's $HOME): one copy in
# the repository, sourced here. Loud when absent: a run that cannot find its
# precedence rule would silently read the production queue under a test env.
# shellcheck disable=SC1091
. "$(dirname "$0")/alert-env.sh" || { echo "$0: cannot source alert-env.sh next to this script -- re-run deploy.sh" >&2; exit 1; }

QUEUE="${ZFS_ALERT_QUEUE:-/var/lib/zfs-snapshot-all/alert-queue.log}"
LEGACY_QUEUE="/root/scripts/warn-queue.log"
HOST=$(hostname -f 2>/dev/null || hostname)
TODAY=$(date '+%Y-%m-%d')

PROCESSING="${QUEUE}.processing"

# Claim the queue first, so findings arriving mid-run land in the NEXT digest
# rather than being summarised and then deleted unread.
if [ -s "$QUEUE" ]; then
    mv "$QUEUE" "$PROCESSING"
else
    : > "$PROCESSING"
fi

# One-time carry-over: anything left by notify-warn.sh v1, which wrote a
# two-column line (epoch, message) to a separate file. Normalised to WARN so a
# host upgraded mid-day does not silently drop what it had already queued.
if [ -s "$LEGACY_QUEUE" ]; then
    awk -F'\t' 'NF>=2 { printf "%s\tWARN\t%s\n", $1, $2 }' "$LEGACY_QUEUE" >> "$PROCESSING"
    rm -f "$LEGACY_QUEUE"
fi

# A QUIET PERIOD MUST STILL REPORT, AND THE CADENCE IS THE ADMIN'S TO SET.
#
# WHY A QUIET HOST MAILS AT ALL. Measured on pve9, 2026-08-22: its MTA was
# local-delivery only and its digest was not even scheduled, so it had reported
# NOTHING for months -- and from the owner's inbox that looked exactly like a
# host with no findings. Three real messages, one of them a genuine digest
# naming 2 alerts and 1 warning, were sitting in /var/mail on the host itself.
# So a quiet host says so on a schedule, and from then on NO mail is itself the
# alarm -- an alarm the owner notices without checking anything.
#
# WHY IT NOW CARRIES THE WHOLE REPORT. Owner, 2026-09-02: "Co, gdy nie ma
# warningow, ani alertow, czy raz w tygodniu tez dostane taka statystyke?" He
# did not, and the arrangement was backwards. The quiet mail was ONE LINE, and
# the state table plus the run figures -- last run, counts, przyrost, transfer,
# timings -- were built further down, AFTER this block had already exited. So
# the periodic report vanished in exactly the weeks it is most worth reading:
# the ones with nothing wrong, where the only question an admin has is whether
# the numbers still look like they did. Findings are not the report; they are
# an interruption to it.
#
# The empty PROCESSING file is therefore kept rather than deleted, and the run
# falls through to the ordinary body. Everything downstream already handles
# zero findings: awk over an empty file yields nothing, TOTAL is 0, and the two
# event blocks are gated on their counts.
#
# CADENCE. ZFS_DIGEST_QUIET takes a weekday (mon..sun, the default is mon),
# 'daily', or 'off'. It governs ONLY the mail that has nothing to report: a day
# with findings sends the digest whatever this says, because suppressing an
# alert on a schedule is not a cadence, it is a lost alert.
#
# 'off' is honoured, and it is the one value that costs a guarantee: with no
# quiet mail there is no week in which silence is distinguishable from a dead
# MTA, which is the failure this block was written for. It stays available
# because this is an administrator's tool, but it is not the default.
#
# Stateless on purpose. No "last report" file to go stale, drift, or come back
# from a backup: the weekday IS the schedule.
QUIET_WHEN="${ZFS_DIGEST_QUIET:-mon}"
QUIET=0
if [ ! -s "$PROCESSING" ]; then
    case "$QUIET_WHEN" in
        off|never)
            rm -f "$PROCESSING"; exit 0 ;;
        daily)
            : ;;
        monthly)
            # The 1st. Spelled out rather than written as "1", because a bare
            # number here reads as a weekday to at least half the people who
            # will edit this file.
            [ "$(date +%d)" = "01" ] || { rm -f "$PROCESSING"; exit 0; } ;;
        [1-9]|[12][0-9]|3[01])
            # A day of the month. Capped at 28 on purpose: 29, 30 and 31 do not
            # exist in every month, and a report that silently skips February
            # is worse than one that refuses to be configured that way.
            if [ "$QUIET_WHEN" -gt 28 ]; then
                echo "alert-digest.sh: ZFS_DIGEST_QUIET=$QUIET_WHEN -- days above 28 do not occur in every month; using 28" >&2
                QUIET_WHEN=28
            fi
            _dom=$(date +%d); _dom="${_dom#0}"
            [ "$_dom" = "$QUIET_WHEN" ] || { rm -f "$PROCESSING"; exit 0; } ;;
        mon|tue|wed|thu|fri|sat|sun)
            _wd=$(printf 'mon tue wed thu fri sat sun' | cut -d' ' -f"$(date +%u)")
            if [ "$_wd" != "$QUIET_WHEN" ]; then rm -f "$PROCESSING"; exit 0; fi ;;
        *)
            echo "alert-digest.sh: ZFS_DIGEST_QUIET='$QUIET_WHEN' is not a weekday, a day of the month, 'monthly', 'daily' or 'off' -- using mon" >&2
            if [ "$(date +%u)" != "1" ]; then rm -f "$PROCESSING"; exit 0; fi ;;
    esac
    QUIET=1
fi

# Collapse to one row per (severity, message): count, first-seen, last-seen.
# Sorted ALERT before WARN, then by count descending -- the worst and the
# noisiest end up at the top of the mail where they get read.
# The fourth column (detail) is what the finding actually SAID -- the failing
# command's output, or the monitor's verdict with the real age and thresholds.
# Kept from the LAST occurrence: for a condition repeating every 15 minutes the
# most recent reading is the one that describes the state now. Lines queued
# before v8/v6 have no fourth column and simply carry no detail.
SUMMARY=$(awk -F'\t' '
{
    sev = $2; if (sev != "ALERT") sev = "WARN"
    key = sev "\t" $3
    count[key]++
    if (!(key in first) || $1 < first[key]) first[key] = $1
    if (!(key in last)  || $1 > last[key])  { last[key] = $1; detail[key] = $4 }
}
END {
    for (k in count) {
        split(k, p, "\t")
        rank = (p[1] == "ALERT") ? 0 : 1
        printf "%d\t%s\t%d\t%s\t%d\t%d\t%s\n", rank, p[1], count[k], p[2], first[k], last[k], detail[k]
    }
}' "$PROCESSING" | sort -t$'\t' -k1,1n -k3,3nr)

ALERT_BODY=""
WARN_BODY=""
N_ALERT=0
N_WARN=0
while IFS=$'\t' read -r rank sev cnt msg first_ep last_ep detail; do
    [ -n "$sev" ] || continue
    # THE DATE, whenever the row is not from the day this digest is sent.
    # This runs at 07:00 and reports what was queued SINCE THE LAST RUN, so a
    # digest almost always carries yesterday's events -- and printing bare
    # times made them read as today's. Measured 2026-09-02 on a production pve1:
    # a DEGRADED pool repaired at 17:45 the previous day was reported as
    # '(07:01 - 16:01)' under a header stamped with the SEND date, and the
    # owner reasonably concluded the pool was still broken. It was not: the
    # events predated the repair by an hour and a half.
    dt1=$(date -d "@$first_ep" '+%Y-%m-%d %H:%M')
    dt2=$(date -d "@$last_ep" '+%Y-%m-%d %H:%M')
    day1="${dt1%% *}"; day2="${dt2%% *}"
    t1="${dt1##* }"; t2="${dt2##* }"
    if [ "$day1" = "$TODAY" ] && [ "$day2" = "$TODAY" ]; then
        range="$t1"; [ "$t1" != "$t2" ] && range="$t1 - $t2"
    elif [ "$day1" = "$day2" ]; then
        range="$day1 $t1"; [ "$t1" != "$t2" ] && range="$day1 $t1 - $t2"
    else
        range="$dt1 - $dt2"
    fi
    # Widest span across every row, for the header below.
    if [ -z "$MIN_EP" ] || [ "$first_ep" -lt "$MIN_EP" ]; then MIN_EP=$first_ep; fi
    if [ -z "$MAX_EP" ] || [ "$last_ep" -gt "$MAX_EP" ]; then MAX_EP=$last_ep; fi
    line=$(printf '  x%-4s %-55s (%s)' "$cnt" "$msg" "$range")
    # Unflatten and indent under the heading it belongs to. \001 went in where
    # the newlines were; a multi-line failure comes back out as multiple lines.
    #
    # A row with NO detail says so, rather than just looking thin: silence there
    # is ambiguous -- it could be an entry queued before the detail existed, or
    # a caller that forgot to pass it -- and the reader cannot tell which.
    if [ -n "$detail" ]; then
        line="$line
$(printf '%s' "$detail" | tr '\001' '\n' | sed 's/^/        /')"
    else
        line="$line
        (bez szczegolow -- wpis zakolejkowany przed przebudowa alertow)"
    fi
    if [ "$sev" = "ALERT" ]; then
        N_ALERT=$((N_ALERT + 1))
        ALERT_BODY="${ALERT_BODY}${line}
"
    else
        N_WARN=$((N_WARN + 1))
        WARN_BODY="${WARN_BODY}${line}
"
    fi
done <<< "$SUMMARY"

TOTAL=$(wc -l < "$PROCESSING")

# ---------------------------------------------------------------------------
# THE CURRENT STATE, PROBED NOW -- and it comes FIRST.
#
# Owner direction 2026-09-02, after a morning mail reported a DEGRADED pool a
# day after the disk had been replaced: state first, period report second.
# Dating the events (v10) made the report honest but still left the reader
# deducing the present from a list of past events. This block answers the only
# question worth asking over breakfast -- is it broken RIGHT NOW -- and a
# repaired fault cannot survive it, because it is measured at send time.
#
# It does NOT make a quiet host start mailing: this runs only when a mail is
# already going out. One mail per host per day stays the rule.
STATE_BODY=""
POOL_BODY=""
STATE_BAD=""
_ZP=$(zpool list -H -o name,health,capacity 2>/dev/null)
if [ -n "$_ZP" ]; then
    while read -r _sn _sh _sc; do
        [ -n "$_sn" ] || continue
        POOL_BODY="$POOL_BODY$(printf '  pula %-12s %-9s zajete %s' "$_sn" "$_sh" "$_sc")
"
        [ "$_sh" = "ONLINE" ] || STATE_BAD="$STATE_BAD pula:$_sn=$_sh"
    done <<< "$_ZP"
fi
# U157/U160 (owner 2026-11-04): the mail is a table of RELATIONS, with the full statistics
# as an HTML attachment. The figures below are still gathered once, by this script; each
# job row is also written as a record into DG_RD for relations_render. No directory -> the
# job-table mail, as before.
DG_RD=$(mktemp -d 2>/dev/null) || DG_RD=""
[ -n "$DG_RD" ] && trap 'rm -rf "$DG_RD"' EXIT
[ -n "$DG_RD" ] && printf '%s\n' "$_ZP" > "$DG_RD/pools.tsv"

# WHICH cron.log. Jobs run as root on some hosts and as a delegated account on
# others, and each writes its own. Reading only root's -- which is what the
# footer used to name -- reports nothing at all on a delegated host.
# HOW FAR BACK THE RUN TABLE LOOKS. Seven days by default (owner, 2026-09-02),
# configurable because the right answer differs per host: a daily mail showing
# a week of trend was the ask, but nothing here should hardcode somebody else's
# retention. The first cut silently assumed two calendar days and said so
# nowhere -- the owner had to ask what the window even was.
DIGEST_DAYS="${ZFS_DIGEST_DAYS:-7}"
case "$DIGEST_DAYS" in ""|*[!0-9]*) DIGEST_DAYS=7 ;; esac
[ "$DIGEST_DAYS" -lt 1 ] 2>/dev/null && DIGEST_DAYS=7
_DSTART=$(date -d "-$((DIGEST_DAYS - 1)) days" '+%Y-%m-%d' 2>/dev/null)
[ -n "$_DSTART" ] || _DSTART=$(date '+%Y-%m-%d')
_SINCE_EP=$(date -d "$_DSTART 00:00:00" +%s 2>/dev/null || echo 0)

# WHAT EACH JOB PUT ON DISK, over the same window as its run figures.
#
# Owner asked for volumes 2026-09-02 and chose the TARGET side. They are NOT in
# the logs -- measured across the whole history, live and rotated, there is not
# one size or rate figure anywhere. The engines can produce them (mbuffer counts
# bytes in every pipeline) but are muted from cron on purpose, so that cron.log
# does not become a rate meter. Un-muting means editing frozen files.
#
# ZFS already knows. A snapshot's written is the space it holds against the
# previous one -- for a received stream, what landed. One bulk call for the host
# costs 0.57s (measured on pve0), needs no engine change and no ssh, and is
# meaningful for BOTH job kinds: a copy job lands data on its target, and a
# snapshot-only job -- pve0 runs several -- pins data where it is.
#
# SAID PLAINLY WHERE IT IS REPORTED: this is data ADDED, not bytes on the wire.
# With compression the stream is smaller than what it writes. Wire bytes are a
# different measurement and would need the engines.
SNAP_VOL=$(zfs list -H -p -t snapshot -o name,written,creation 2>/dev/null)

# ZFS_CRON_LOGS overrides the search, for the same reason ZFS_ALERT_QUEUE
# already does: without a seam the only way to check this block is to grep the
# script, which tests the text and not the behaviour.
CRON_LOGS="${ZFS_CRON_LOGS:-}"
if [ -z "$CRON_LOGS" ]; then
    for _cl in /root/scripts/cron.log /home/*/cron.log; do
        [ -r "$_cl" ] || continue
        CRON_LOGS="$CRON_LOGS $_cl"
        # ROTATED FILES TOO, or a window longer than the live log silently
        # under-reports. logrotate here is monthly with rotate 24, so on the
        # 1st of a month the live log holds almost nothing and every number
        # in this table would be wrong without saying so. Measured on pve0
        # 2026-09-02: cron.log began 09-01 because rotation ran 08-31 23:21,
        # with twenty megabytes of August sitting in cron.log.1.
        #
        # Selected by MTIME rather than by reading them: a rotated file last
        # written before the window starts cannot hold a run inside it, and
        # deciding that costs no decompression. `compress` + `delaycompress`
        # means .1 is plain and .2+ are .gz, which is why the reader below is
        # `zcat -f` -- it takes both.
        _i=1
        while [ "$_i" -le 26 ]; do
            _hit=0
            for _rot in "$_cl.$_i" "$_cl.$_i.gz"; do
                [ -r "$_rot" ] || continue
                _hit=1
                if [ -n "$(find "$_rot" -newermt "$_DSTART" 2>/dev/null)" ]; then
                    CRON_LOGS="$CRON_LOGS $_rot"
                else
                    _hit=2
                fi
            done
            [ "$_hit" = "1" ] || break
            _i=$((_i + 1))
        done
    done
fi

# ONE pass over the logs feeds both blocks: the per-job verdict above and the
# run table below.
#
# Durations come from SECONDS-OF-DAY arithmetic, not mktime: every host here
# runs mawk (measured 2026-09-02 on a production pve1, pve9 and pve2) and mawk
# has no mktime. A gawk-ism would have failed silently across the estate. The
# timezone offset in the stamp cancels between the two ends of a pair, so a
# duration is right regardless of it; only a job spanning midnight needs the
# wrap, which is what the +86400 is for.
# A RUN THAT SKIPPED IS NOT A RUN THAT WORKED.
#
# snapsend.sh locks per DATASET, not per snapshot family, and the loser exits
# ZERO after logging "Another instance targeting the same datasets is already
# running -- skipping this run". For the same job overlapping itself that is
# right: skipping beats two concurrent sends. For two DIFFERENT families it
# silently drops a snapshot, and the job still reports rc=0, so the table above
# counts it as a successful run.
#
# Measured on pve0, 2026-09-01 22:00: the daily and monthly jobs fire in the
# same minute on hdd/lxc, the daily one lost the lock on TWO datasets, and the
# only trace was a stats line nobody reads. It surfaced 33 hours later as 57
# queued "getting stale" warnings, which is a bad way to learn about it.
#
# The window filter compares the DATE PART of an ISO-8601 UTC stamp against a
# local date. Up to a couple of hours of skew at the boundary, accepted: this
# block exists to say THAT a run was skipped, not to be the authority on which
# second it happened.
# ZFS_STATS_LOGS overrides the search, exactly as ZFS_CRON_LOGS does for the
# run logs -- a test that cannot point this at a fixture can only assert that
# nothing was found, which proves nothing about the code that finds it.
STATS_LOGS="${ZFS_STATS_LOGS:-}"
if [ -z "$STATS_LOGS" ]; then
    for _sl in /root/scripts/zfs-snapshot-stats.log /home/*/zfs-snapshot-stats.log; do
        [ -r "$_sl" ] || continue
        STATS_LOGS="$STATS_LOGS $_sl"
        _i=1
        while [ "$_i" -le 26 ]; do
            _hit=0
            for _rot in "$_sl.$_i" "$_sl.$_i.gz"; do
                [ -r "$_rot" ] || continue
                _hit=1
                if [ -n "$(find "$_rot" -newermt "$_DSTART" 2>/dev/null)" ]; then
                    STATS_LOGS="$STATS_LOGS $_rot"
                else
                    _hit=2
                fi
            done
            [ "$_hit" = "1" ] || break
            _i=$((_i + 1))
        done
    done
fi

SKIP_ROWS=""
if [ -n "$STATS_LOGS" ]; then
    SKIP_ROWS=$(zcat -f $STATS_LOGS 2>/dev/null | grep -F '"status":"skipped_lock"' | awk -v since="$_DSTART" '
        {
            t = ""; d = ""
            if (match($0, /"time":"[^"]+"/))     t = substr($0, RSTART + 8,  RLENGTH - 9)
            if (match($0, /"dataset":"[^"]*"/))  d = substr($0, RSTART + 11, RLENGTH - 12)
            if (t == "" || substr(t, 1, 10) < since) next
            print t "\t" d
        }' | sort -u)
fi

RUN_ROWS=""
if [ -n "$CRON_LOGS" ]; then
    # --- twin: run-rows (the SAME text lives in zfs-backup.sh cmd_job_stats; a test pins equality) ---
    RUN_ROWS=$(zcat -f $CRON_LOGS 2>/dev/null | awk -v dstart="$_DSTART" '
    function secs(t) { return substr(t,12,2)*3600 + substr(t,15,2)*60 + substr(t,18,2) }
    /ZFS-JOB BEGIN/ || /ZFS-JOB END/ {
        day = substr($1,1,10)
        if (day < dstart) next
        lbl = ""
        for (i = 5; i <= NF; i++) { if ($i ~ /^rc=/) break; lbl = lbl (lbl == "" ? "" : " ") $i }
        if (lbl == "") next
        # A STACK of open starts per label, not one slot (lab, 2026-11-07): a second
        # start of a line while the first holds the lock ends at once with rc 75, so
        # an END belongs to the NEWEST open start. One slot let the skip take the real
        # start of the real run and left that run with no duration. rc 75 is a skip, not a failure.
        if ($3 == "BEGIN") { bt[lbl, ++sp[lbl]] = secs($1); next }
        rc = ($NF ~ /^rc=/) ? substr($NF,4) + 0 : 0
        n[lbl]++
        if (rc != 0 && rc != 75) f[lbl]++
        # awk variables are global, so d survives the previous END line. Without
        # this reset a job whose BEGIN fell outside the window would inherit the
        # duration of whatever ran before it -- a wrong number that looks right.
        d = ""
        if (sp[lbl] > 0) {
            d = secs($1) - bt[lbl, sp[lbl]]; if (d < 0) d += 86400
            # a skip (rc 75) took no time and copied nothing: not in the average, not the max
            if (rc != 75) { tot[lbl] += d; c[lbl]++; if (d > mx[lbl]) mx[lbl] = d }
            delete bt[lbl, sp[lbl]]; sp[lbl]--
        }
        # THE NEWEST run, compared -- not the last line read. The logs are fed
        # live-file-first and rotated-after, so "last seen" is the END OF THE
        # OLDER FILE. Rendered on pve0 that reported every job as last run on
        # 08-31 while they had all run this morning.
        # The duration of THAT run travels with it. The table used to show the
        # sum over the window, which is not a quantity anyone reads -- 27 runs
        # of a job add up to a number that says nothing about how long the job
        # takes. Owner, 2026-09-02: "Naglowek czas laczny jest bez sensu."
        # Compared to the SECOND, shown to the minute (lab 2026-11-07): a skip and the real
        # run ending in the same minute tied, and the one read first -- the skip -- stayed last.
        t = day " " substr($1,12,5); ts = day " " substr($1,12,8)
        if (!(lbl in lastkey) || ts > lastkey[lbl]) { lastkey[lbl] = ts; lastwhen[lbl] = t; lastrc[lbl] = rc; lastdur[lbl] = (d == "" ? -1 : d) }
    }
    END { for (k in n) printf "%s\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\n", k, n[k], f[k]+0, (c[k] ? tot[k]/c[k] : -1), mx[k]+0, lastwhen[k], lastrc[k], tot[k]+0, lastdur[k]+0 }
    ' | sort)
    # --- twin end: run-rows ---

    # PER-DATASET FIGURES, KEYED ON THE DATASET AND NOTHING ELSE.
    #
    # The engines log each transfer separately, and RECV CMD names the TARGET
    # dataset -- the side "written" is measured on, so both halves key on the
    # same name:
    #
    #   03:00:45 - SEND CMD: zfs send -c -I rpool/data/vm-106-disk-1@...
    #   03:00:45 - RECV CMD: zfs recv -F -s -u hdd/backups/pve1/rpool/data/vm-106-disk-1
    #   03:00:54 - Transfer completed successfully
    #
    # THE FIRST CUT BRACKETED THESE BETWEEN ZFS-JOB BEGIN AND END, AND THAT WAS
    # WRONG. Two jobs owned by the same account write to the SAME cron.log, and
    # they overlap: measured on pve0, 2026-09-02, the account log contains two
    # consecutive BEGIN lines with no END between them (daily backup (vm-101)
    # opening while daily backup (vm-103...) is still running). The engine lines
    # carry no job identity at all, so whichever BEGIN was seen last claimed
    # them. Consequence in a delivered mail: archive backup reported 17
    # transfers per dataset instead of 27, three of the missing ones were
    # credited to hourly backup -- a job that never writes to that target -- and
    # the "pozostale" remainder was inflated from 48s to 14m42s to make the
    # column still close. A resettable per-file guard changed nothing, because
    # the interleaving is INSIDE one file.
    #
    # The dataset name is the only identity these lines actually carry, so it is
    # the only thing attribution may rest on. Ordering stops mattering, and so
    # does which log the job wrote to. Where two jobs share a target the caller
    # refuses the figures rather than guessing -- see the ambiguity guard below.
    #
    # secs() reads the whole line, not a field: the job markers are one ISO
    # field while the engine lines put the clock in a second field, and both put
    # the same digits at the same offsets of the LINE.
    # --- twin: ds-rows (the SAME text lives in zfs-backup.sh cmd_job_stats; a test pins equality) ---
    DS_ROWS=$(zcat -f $CRON_LOGS 2>/dev/null | awk -v dstart="$_DSTART" '
    function secs(t) { return substr(t,12,2)*3600 + substr(t,15,2)*60 + substr(t,18,2) }
    substr($0,1,10) < dstart { next }
    /EXECUTING TRANSFER:/ { t0 = secs($0); ds = ""; next }
    /RECV CMD:/ { ds = $NF; next }
    /Transfer completed successfully/ {
        if (t0 > 0 && ds != "") {
            d = secs($0) - t0; if (d < 0) d += 86400
            n[ds]++; tot[ds] += d; if (d > mx[ds]) mx[ds] = d
            # The newest transfer of THIS dataset, by wall clock, so the row can
            # show what the last run cost rather than a sum nobody reads.
            if ($0 > lastline[ds]) { lastline[ds] = $0; lastdur[ds] = d }
        }
        t0 = 0; ds = ""
    }
    END { for (k in n) printf "%s\t%d\t%d\t%d\t%d\n", k, n[k], tot[k], mx[k], lastdur[k]+0 }
    ')
    # --- twin end: ds-rows ---

    # THE WINDOW THE NUMBERS ACTUALLY COVER, measured rather than named.
    #
    # The header used to read "PRZEBIEGI ZADAN (2026-09-01, 2026-09-02)" -- two
    # dates and a comma, which says neither from-to nor anything else. Worse, it
    # hid a real asymmetry: this runs at 07:00, so "today" is a PARTIAL day and
    # a count of 34 for an hourly job is 24 from yesterday plus 10 from today.
    # Printing the first and last run actually counted states the span instead
    # of claiming it, and makes that arithmetic self-evident.
    #
    # String comparison is enough: "YYYY-MM-DD HH:MM" sorts chronologically.
    RUN_WINDOW=$(zcat -f $CRON_LOGS 2>/dev/null | awk -v dstart="$_DSTART" '
    /ZFS-JOB END/ {
        day = substr($1,1,10)
        if (day < dstart) next
        t = day " " substr($1,12,5)
        if (mn == "" || t < mn) mn = t
        if (mx == "" || t > mx) mx = t
    }
    END { if (mn != "") { if (mn == mx) printf "%s\n", mn; else printf "%s - %s\n", mn, mx } }
    ')
fi

# The per-job half of the state block: what each job did on its LAST run. A job
# whose newest run failed is the present tense; one that failed earlier and has
# succeeded since is history, and belongs in the events below.
# WHICH JOBS ARE STILL SCHEDULED, and what each one actually touches.
#
# A job deleted from cron keeps its last run in the log for ever, so its final
# failure would pin the verdict to UWAGA with nothing left to fix.
#
# TWO CRON FORMATS, and the first cut of this knew only one. It matched
# zfs-job.sh "<label>", which is what a host generated by current main runs.
# Production hosts still carry the older INLINE form, where the label lives
# inside the job's own echo:
#
#   1 * * * * echo "... ZFS-JOB BEGIN pve0 hourly backup (...)" >>/…/cron.log; …
#
# On those nothing matched and EVERY job was reported as gone -- seen by the
# owner on a production pve0 minutes after v11 shipped. The lesson is the one
# this project keeps relearning: a format read off ONE host is not the estate's
# format. Both spellings are matched now, and both yield "<host> <label>", whose
# first word is dropped to match the log.
LIVE_LABELS=""
JOB_DATASETS=""
for _u in root $(ls /home 2>/dev/null); do
    _cr=$(crontab -u "$_u" -l 2>/dev/null)
    [ -n "$_cr" ] || continue
    while IFS= read -r _line; do
        _lab=$(printf '%s' "$_line" | grep -oE '(zfs-job\.sh "|ZFS-JOB BEGIN )[^"]+' | head -1 | sed 's/^zfs-job\.sh "//; s/^ZFS-JOB BEGIN //; s/^[^ ]* //')
        [ -n "$_lab" ] || continue
        LIVE_LABELS="$LIVE_LABELS
$_lab"
        # WHAT the job touches. A dataset argument is a quoted token that holds
        # a '/' and does NOT begin with one -- which tells hdd/data/vm-101-disk-0
        # and acct@host:pool/ds apart from every filesystem path on the line
        # (/home/..., /root/...) and from patterns like automated_hourly_, which
        # carry no slash at all. A DATASET PATH ALSO HAS NO SPACES, which is what
        # keeps the inline format's own echo text out: on pve0 the notify label is
        # literally 'hdd/lxc', so `... ZFS-JOB BEGIN pve0 daily backup (hdd/lxc)`
        # passed every other filter and was listed as a dataset.
        # Quoted tokens are the even fields once the line
        # is split on the quote character; no nested-quote parsing needed.
        _ds=$(printf '%s' "$_line" | tr '"' '
' | awk 'NR%2==0' | grep -E '^[^/ ]+/[^ ]*$' | grep -vE '[$()]|\.(sh|log)' | paste -sd, -)
        # HOW MANY dataset arguments the engine got. Two means the second is a
        # TARGET (snapsend ... "src" "tgt"); one means snapshot-only, and
        # then every dataset in that single comma-list is where data lands.
        # Taking "the last one" for both reported a five-dataset snapshot job
        # as 0B on pve0 -- it summed one disk that happened not to grow.
        _dsn=$(printf '%s' "$_line" | tr '"' '\n' | awk 'NR%2==0' | grep -cE '^[^/ ]+/[^ ]*$')
        # WHICH SNAPSHOT FAMILY THIS JOB OWNS.
        #
        # Without it every tier sharing a scope is credited with the whole
        # scope. Rendered on pve1: five snapshot jobs over rpool/data, each
        # reporting 494G, because the volume summed every snapshot under the
        # scope regardless of which job made it. Same family of defect as the
        # prune that was credited with 525 GB.
        #
        # The engines take it as -m, and gen-cron writes it quoted:
        #   snapsend.sh -m "automated_hourly_" -r -v 3 "rpool/data"
        # -t means the base IS the target (the restore direction), so the job
        # writes to <target> itself rather than <target>/<source>. snapsend.sh
        # decides it at snapsend.sh:2570; getting it wrong here would scope the
        # job's volume to a path that does not exist.
        case " $_line " in *" -t "*) _texact=1 ;; *) _texact=0 ;; esac
        _pfx=$(printf '%s' "$_line" | grep -oE '\-m +"[^"]+"' | head -1 | sed 's/.*"\(.*\)"/\1/')
        [ -n "$_pfx" ] || _pfx=$(printf '%s' "$_line" | grep -oE '\-m +[A-Za-z0-9_.:-]+' | head -1 | sed 's/^-m *//')
        _tgt=""
        [ "${_dsn:-0}" -ge 2 ] && _tgt=${_ds##*,}
        # WHERE THIS JOB ACTUALLY LANDS ITS DATA, computed once here so that the
        # volume and the ambiguity guard below agree by construction instead of
        # each deriving it their own way. snapsend.sh writes <target>/<source>
        # per source (snapsend.sh:2570); -t makes the base itself the target.
        _kid=""
        if [ -n "$_tgt" ] && [ "$_texact" = "1" ]; then
            _kid="$_tgt"
        elif [ -n "$_tgt" ]; then
            _srcs2="${_ds%,*}"
            _oi2="$IFS"; IFS=','
            for _s2 in $_srcs2; do IFS="$_oi2"; [ -n "$_s2" ] && _kid="${_kid:+$_kid,}$_tgt/$_s2"; done
            IFS="$_oi2"
        else
            _kid="$_ds"
        fi
        [ -n "$_ds" ] && JOB_DATASETS="$JOB_DATASETS
$_lab	$_ds	$_tgt	$_pfx	$_texact	$_kid"
        # Which jobs actually put data somewhere. delsnaps prunes and
        # check-snap-age only looks; neither adds a byte, so neither gets a
        # volume -- crediting a prune with what grew under its scope reported
        # pve0's `bookmarks prune` as 525 GB, the whole pool's week.
        case "$_line" in *snapsend.sh*|*snapget.sh*) SEND_LABELS="$SEND_LABELS
$_lab" ;; esac
    done <<< "$_cr"
done
nl='
'
# ONE TABLE, not two. The state block and the run table listed the SAME jobs --
# two views of one set -- so a job appeared twice and the mail carried its
# datasets twice with it. Owner, 2026-09-02: put the run figures on the state
# row and say once, underneath, over what period they were measured.
#
# AND THE UNION, not just what ran. Both blocks were built from the LOG, so a
# job that is scheduled but has not run inside the window was in neither --
# invisible in a mail that claims to report the current state. Measured on pve0
# the same day: 26 jobs in cron, 24 with a run in a 7-day window, and the two
# missing were `annual backup (hdd/lxc)` and `annual backup (subvol-105-disk-0)`.
# An annual job cannot appear in a week, and silence is exactly what an operator
# cannot notice. Such a job is listed and NOT judged: the digest does not know
# each job's cadence, so it reports the fact and leaves the reading to a human.
# Bytes an operator can read at a glance. Integer arithmetic only: this runs on
# every host and none of them is guaranteed anything but POSIX shell tools.
human_bytes() {   # <bytes> -> e.g. 69M
    _hb=${1:-0}
    case "$_hb" in ""|*[!0-9]*) printf -- "-"; return 0 ;; esac
    if   [ "$_hb" -ge 1099511627776 ]; then printf "%sT" $(( _hb / 1099511627776 ))
    elif [ "$_hb" -ge 1073741824 ];    then printf "%sG" $(( _hb / 1073741824 ))
    elif [ "$_hb" -ge 1048576 ];       then printf "%sM" $(( _hb / 1048576 ))
    elif [ "$_hb" -ge 1024 ];          then printf "%sK" $(( _hb / 1024 ))
    else printf "%sB" "$_hb"
    fi
}

# THE WHOLE JOB IS RENDERED IN ONE UNIT, so its rows can be added on the page.
#
# Owner, 2026-09-02, choosing between three renderings. The bytes always summed
# exactly -- measured on pve0, the job total and the sum of its datasets were
# the same 260980736 -- but each value was rounded to its OWN unit before
# printing, so 211M + 37M read as 248 under a total of 249. Worse, a big job
# mixed units (42G beside 467M) and then no amount of precision makes the
# column addable at all.
#
# The unit comes from the JOB, and every dataset under it is printed in that
# unit with one decimal. The cost is real and was accepted knowingly: a small
# component of a large job loses detail (467M shows as 0.5G). What is bought is
# that the column can be checked without a calculator, which is the property
# the owner has asked for three times in this table.
unit_of() {   # <bytes> -> T|G|M|K|B
    _uo=${1:-0}
    case "$_uo" in ""|*[!0-9]*) printf "B"; return 0 ;; esac
    if   [ "$_uo" -ge 1099511627776 ]; then printf "T"
    elif [ "$_uo" -ge 1073741824 ];    then printf "G"
    elif [ "$_uo" -ge 1048576 ];       then printf "M"
    elif [ "$_uo" -ge 1024 ];          then printf "K"
    else printf "B"
    fi
}

human_bytes_in() {   # <bytes> <unit> -> e.g. 41.9G
    case "${1:-}" in ""|*[!0-9]*) printf -- "-"; return 0 ;; esac
    # awk, not shell arithmetic: the division needs a fraction, and the sums
    # here run past what a shell integer would hold anyway.
    awk -v b="$1" -v u="$2" 'BEGIN {
        if      (u == "T") printf "%.2fT", b / 1099511627776
        else if (u == "G") printf "%.2fG", b / 1073741824
        else if (u == "M") printf "%.2fM", b / 1048576
        else if (u == "K") printf "%.2fK", b / 1024
        else               printf "%dB", b
    }'
}

# The seconds the rate was DIVIDED BY, made readable. It is printed next to the
# rate on purpose: przyrost / czas lacz. = transfer is then arithmetic the admin
# can check on the row, instead of a number they have to trust. Sums over the
# window run to hours, so plain seconds stop being a quantity anyone reads.
human_secs() {   # <seconds> -> 47s | 9m12s | 1h26m
    # SECONDS ARE SHOWN, not rounded away, so the column CLOSES.
    #
    # Owner, 2026-09-02: "9m+1m+2m<>26". Truncating each value to whole
    # minutes lost up to 59 s per row, so four rows that summed exactly in
    # seconds displayed as 25 against 26 -- and a column that visibly does not
    # add up is one the reader has to be talked out of distrusting, whatever a
    # footnote says. m+s costs two characters and makes the addition checkable
    # on the page.
    case "${1:-}" in ""|*[!0-9]*) printf -- "-"; return 0 ;; esac
    if [ "$1" -lt 60 ]; then printf '%ss' "$1"
    elif [ "$1" -lt 3600 ]; then printf '%dm%02ds' "$(( $1 / 60 ))" "$(( $1 % 60 ))"
    else printf '%dh%02dm' "$(( $1 / 3600 ))" "$(( ($1 % 3600) / 60 ))"
    fi
}

# Throughput this job actually achieved: what it added, over the seconds it
# spent doing it. DERIVED, and labelled that way -- the wire figure would need
# the engines, and with compression the two differ. A job that added nothing,
# or ran for no measurable time, gets a dash rather than a division.
human_rate() {   # <bytes> <seconds> -> e.g. 27M/s
    case "${1:-}" in ""|*[!0-9]*) printf -- "-"; return 0 ;; esac
    case "${2:-}" in ""|*[!0-9]*) printf -- "-"; return 0 ;; esac
    [ "$1" -gt 0 ] && [ "$2" -gt 0 ] || { printf -- "-"; return 0; }
    printf "%s/s" "$(human_bytes $(( $1 / $2 )))"
}

# The TARGET of a job is the LAST dataset on its cron line -- sources come
# first, the destination last (`snapsend ... "src1,src2" "tgt"`). A job with a
# single dataset argument is snapshot-only: it lands nothing elsewhere, so the
# dataset itself is where its data stays. A REMOTE target (user@host:pool/ds)
# cannot be measured from here, and is reported as unknown rather than
# silently measured on the wrong side.
job_volume() {   # <datasets> <label> <target|""> <family|""> -> written over the window
    # A PRUNE JOB ADDS NOTHING. Summing what grew under its scope credits it
    # with data another job wrote -- on pve0 'bookmarks prune' was reported as
    # 525 GB, which is the whole pool for a week. Only a job that creates or
    # receives snapshots gets a figure.
    case "$nl$SEND_LABELS$nl" in *"$nl$2$nl"*) ;; *) printf -- "-"; return 0 ;; esac
    _jt="$3"
    [ -n "$_jt" ] || _jt="$1"
    case "$_jt" in *:*) printf -- "?"; return 0 ;; esac
    [ -n "$_jt" ] || { printf -- "-"; return 0; }
    # AND A TIER IS NOT ITS WHOLE SCOPE. Five snapshot jobs over one dataset
    # each claimed 494G on pve1, because the sum ignored which job made the
    # snapshot. Restricted to this job's own family the tiers stop overlapping
    # and the numbers become attributable.
    printf '%s\n' "$SNAP_VOL" | awk -F'\t' -v tl="$_jt" -v since="$_SINCE_EP" -v fam="$4" '
        BEGIN { n = split(tl, t, ",") }
        { p = index($1, "@"); if (p == 0) next; ds = substr($1, 1, p - 1); sn = substr($1, p + 1) }
        fam != "" && index(sn, fam) != 1 { next }
        $3 + 0 >= since + 0 {
            for (i = 1; i <= n; i++)
                if (ds == t[i] || index(ds, t[i] "/") == 1) { s += $2; break }
        }
        # %.0f, never %d: mawk clamps an integer conversion at INT_MAX, so
        # every sum above ~2.1 GB printed as exactly 2147483647. Measured on
        # pve0 -- three unrelated jobs all reported "1G" because all three had
        # been clamped to the same number. Sums are doubles internally; only
        # the conversion was lossy.
        END { printf "%.0f", s + 0 }
    '
}

# What ONE dataset received over the window. Same measurement as job_volume,
# narrowed to a single name -- the job total is the sum of these, which is what
# lets the indented rows be checked against the row above them.
ds_volume() {   # <dataset> <family|""> -> bytes written over the window
    printf '%s\n' "$SNAP_VOL" | awk -F'\t' -v t="$1" -v since="$_SINCE_EP" -v fam="$2" '
        { p = index($1, "@"); if (p == 0) next; ds = substr($1, 1, p - 1); sn = substr($1, p + 1) }
        fam != "" && index(sn, fam) != 1 { next }
        $3 + 0 >= since + 0 {
            if (ds == t || index(ds, t "/") == 1) s += $2
        }
        END { printf "%.0f", s + 0 }
    '
}

# The per-dataset time figures for one target dataset, or nothing.
#
# AMBIGUITY IS REFUSED, NOT GUESSED. The transfer lines name a dataset and no
# job, so if two jobs write to the same target there is no honest way to say
# which one moved those bytes -- and a plausible wrong attribution is worse
# than a blank, because it survives being looked at. The caller therefore
# passes the number of jobs claiming this dataset, and anything above one gets
# no figures.
ds_times() {   # <target-dataset> <claimants> -> "n<TAB>total<TAB>max<TAB>last" or ""
    [ "${2:-1}" = "1" ] || return 0
    printf '%s\n' "$DS_ROWS" | awk -F'\t' -v d="$1" '$1 == d { printf "%s\t%s\t%s\t%s", $2, $3, $4, $5; exit }'
}

# How many scheduled jobs land data in this dataset. One is the ordinary case;
# more means the transfer lines cannot be attributed and the row says so by
# staying blank.
#
# Counted against each job's OWN CHILDREN, not its target root. Four jobs
# Counted against each job's OWN CHILDREN, not its target root, and only among
# jobs that actually WRITE. Counting by root called four jobs sharing
# hdd/backups/pve2 mutually ambiguous; counting prunes as claimants was worse --
ds_claimants() {   # <target-dataset> -> count
    printf '%s\n' "$JOB_DATASETS" | awk -F'\t' -v c="$1" -v send="$SEND_LABELS" '
        BEGIN { n = split(send, s, "\n"); for (i = 1; i <= n; i++) if (s[i] != "") issend[s[i]] = 1 }
        $6 == "" || !($1 in issend) { next }
        {
            m = split($6, kid, ",")
            for (i = 1; i <= m; i++)
                if (kid[i] != "" && (c == kid[i] || index(c, kid[i] "/") == 1)) { seen[$1] = 1; break }
        }
        END { k = 0; for (x in seen) k++; print k }
    '
}

SEEN_LABELS=""
HAS_DS_ROWS=0
if [ -n "$RUN_ROWS" ]; then
    while IFS=$'\t' read -r _k _n _f _avg _mx _lw _lrc _tot _ldur; do
        [ -n "$_k" ] || continue
        SEEN_LABELS="$SEEN_LABELS
$_k"
        # The parenthetical joins several datasets' notify words with '+',
        # which gen-cron does when it merges them onto one cron line (IFS=+ at
        # gen-cron.sh:3263). Owner asked for commas -- rendered here and not
        # changed there, because changing the join rewrites the label in every
        # generated cron line and every host's crontab differs at the next
        # regeneration.
        _full=$(printf '%s' "${_k#profile__*__}" | tr '+' ',')
        _dsl=$(printf '%s\n' "$JOB_DATASETS" | awk -F'\t' -v k="$_k" '$1==k {print $2; exit}')
        _tg=$(printf '%s\n' "$JOB_DATASETS" | awk -F'\t' -v k="$_k" '$1==k {print $3; exit}')
        # The sources are the datasets the job acts ON. When a target exists it
        # is the LAST entry and is where the data lands, so it is not one of
        # them -- counting it as a component would double every total against
        # the row above.
        if [ -n "$_tg" ]; then _srcs="${_dsl%,*}"; else _srcs="$_dsl"; fi
        # COUNTED IN ONE PLACE, so the value cannot arrive as two lines.
        #
        # It used to be 'grep -c . || echo 0', and grep -c PRINTS 0 and exits 1
        # when it matches nothing -- so the fallback appended a second zero and
        # _nsrc arrived as TWO LINES instead of one. Every comparison against
        # it then failed with "integer expression expected" on stderr, on
        # EVERY run of a job whose cron line quotes no dataset. Seen on
        # pve9/pve9b/pve10, twenty lines a run, straight into cron.log. The
        # arithmetic still fell the right way by accident, which is why
        # nothing else caught it. The backtick guard in test/alertmail does
        # not cover this: a comment that BREAKS ACROSS LINES turns its second
        # half into a command, and that is what it did here -- three times in
        # one day, from the same escaping mistake.
        _nsrc=$(printf '%s' "$_srcs" | tr ',' '\n' | grep -c .); _nsrc="${_nsrc:-0}"
        # ONE DATASET STAYS ON THE ROW; SEVERAL GO UNDERNEATH.
        #
        # Owner, 2026-09-02: "jesli zadanie ma wiele datasets, to pod nazwa
        # zadania robimy wciecie i listujemy kazdy dataset osobno wraz z danymi
        # dot. transferu dla tego dataset. A na gorze nad wcieciem w linii dot.
        # zadania bedzie to sumarycznie."
        #
        # The parenthetical is dropped only in that case: it is what pushed the
        # columns out of line (a five-dataset job rendered as
        # "daily backup (vm-103-disk-0,vm-104-disk..." and every later column on
        # that row sat four characters right of its heading). A single-dataset
        # job keeps it, because it is short, it is the job's identity in the
        # crontab, and moving it to a line of its own would double the table for
        # no gain.
        if [ "${_nsrc:-0}" -ge 2 ]; then _disp="${_full%% (*}"; else _disp="$_full"; fi
        # Cut to the column the row actually has. This used to cut at 42 while
        # the field was 38 -- four characters of overhang, and the misalignment
        # the owner photographed.
        [ ${#_disp} -gt 38 ] && _disp="${_disp:0:35}..."
        case "$nl$LIVE_LABELS$nl" in *"$nl$_k$nl"*) _live=1 ;; *) _live=0 ;; esac
        # ONE FACT PER COLUMN. The time column used to carry the outcome too --
        # "OK  2026-09-02 09:00" under a heading that says "czas" -- so the
        # owner reasonably asked what OK was doing there. The timestamp stands
        # alone now, and a run that FAILED breaks the pattern on purpose: the
        # normal case lines up, the exception sticks out.
        if [ "$_live" -eq 0 ]; then
            _st="$_lw  (juz nie w cronie)"
        elif [ "$_lrc" = "0" ]; then
            _st="$_lw"
        elif [ "$_lrc" = "8" ]; then
            # U159 (pve11 2026-11-04): rc=8 is a run WITHOUT quiescing the guest -- the
            # snapshot exists, crash-consistent (snapsend/snapget "exit 8"). A warning,
            # not a failed run: it was read as "PADL" and counted as a fault.
            _st="$_lw  (bez zamrozenia)"
        else
            _st="$_lw  (PADL rc=$_lrc)"
            STATE_BAD="$STATE_BAD zadanie:$_full"
        fi
        _pf=$(printf '%s\n' "$JOB_DATASETS" | awk -F'\t' -v k="$_k" '$1==k {print $4; exit}')
        # THE JOB OWNS ITS OWN CHILDREN, NOT THE WHOLE TARGET.
        #
        # job_volume used to sum over the target ROOT with only the family as a
        # filter, which is right exactly when one job owns that root. Measured on
        # pve2, where FOUR jobs land in hdd/backups/pve2: "daily backup (BIM
        # server)" and "daily backup (root)" reported the SAME 732.77M -- each
        # credited with the other's bytes -- and "hourly backup (nextcloud)",
        # whose prefix is the broad "automated_", was credited with 259.32G, the
        # entire backup pool for a week.
        #
        # A job writes to <target>/<source> for each of its sources, and that is
        # the only scope it owns. Summing those is the same measurement the
        # indented rows already make per dataset, so the row and its components
        # now describe the same thing by construction.
        _kids=$(printf '%s\n' "$JOB_DATASETS" | awk -F'\t' -v k="$_k" '$1==k {print $6; exit}')
        [ -n "$_kids" ] || _kids="$_dsl"
        _vb=$(job_volume "$_kids" "$_k" "" "$_pf")
        _u=$(unit_of "$_vb")
        # A RATE NEEDS SOMETHING TO HAVE MOVED.
        #
        # A local snapshot job carries nothing across a link, and its duration
        # is the second it took to make the snapshot -- not the hour over which
        # the data was written. Dividing one by the other produced "494G/s" on
        # pve1, a number that is not wrong so much as meaningless. Only a job
        # with a target gets a rate.
        if [ -n "$_tg" ]; then _rt=$(human_rate "$_vb" "$_tot"); else _rt="-"; fi
        # The components, each measured on ITS OWN target dataset. Indented to
        # 6 so the numeric columns land under the same headings as the summary
        # above them, and the two agree by construction: the volumes sum to the
        # job's.
        # Cleared for EVERY job, not just the branch that fills it. Resetting it
        # inside the multi-dataset branch left a single-dataset job appending the
        # PREVIOUS job's rows -- bookmarks prune rendered with archive backup's
        # datasets under it.
        _DSBLOCK=""
        # EVERY job lists its datasets, not only the multi-dataset ones.
        #
        # The old threshold was two, on the premise that a one-dataset job is
        # identified by its parenthetical. That premise holds on pve0, where the
        # parentheticals ARE dataset names, and fails on pve2, where they are
        # human labels: "daily backup (BIM server)" never named
        # rpool/data/vm-106-disk-0 anywhere in the mail. Measured -- pve2 has
        # four such jobs and none of their labels name the dataset; pve0 has six
        # and all of them do.
        #
        # Owner chose the predictable rule over the clever one: always expand,
        # no substring guessing about whether a label already says it. The cost
        # is about 33 mostly-redundant lines on pve0 and was accepted knowingly.
        if [ "${_nsrc:-0}" -ge 1 ]; then
            HAS_DS_ROWS=1
            _oldifs="$IFS"; IFS=','
            for _s in $_srcs; do
                IFS="$_oldifs"
                [ -n "$_s" ] || continue
                # Where this dataset's data LANDS -- the side 'written' counts.
                if [ -n "$_tg" ]; then _child="$_tg/$_s"; else _child="$_s"; fi
                _dv="-"; _dr="-"; _dd="-"; _da="-"; _dm="-"; _dn=""
                case "$nl$SEND_LABELS$nl" in
                    *"$nl$_k$nl"*)
                        case "$_tg" in
                            *:*) _dv="?" ;;
                            *)   _dv=$(human_bytes_in "$(ds_volume "$_child" "$_pf")" "$_u") ;;
                        esac ;;
                esac
                # Times exist only where the engine logged a transfer for this
                # dataset. A snapshot or prune job has none, and dividing the
                # job's duration between its datasets would look measured and
                # be invented.
                _dt=$(ds_times "$_child" "$(ds_claimants "$_child")")
                if [ -n "$_dt" ]; then
                    _dn=$(printf '%s' "$_dt" | cut -f1)
                    _dtot=$(printf '%s' "$_dt" | cut -f2)
                    _dmx=$(printf '%s' "$_dt" | cut -f3)
                    _dlst=$(printf '%s' "$_dt" | cut -f4)
                    case "$_tg" in *:*) ;; *) _dr=$(human_rate "$(ds_volume "$_child" "$_pf")" "$_dtot") ;; esac
                    if [ "${_dlst:-0}" -gt 0 ]; then _dd=$(human_secs "$_dlst"); else _dd="-"; fi
                    _da="$(( _dn > 0 ? _dtot / _dn : 0 ))s"
                    _dm="${_dmx}s"
                fi
                # A PRUNE JOB HAS NOTHING PER DATASET, so its components print
                # as bare names rather than as a column of dashes. Six lines of
                # "-  -  -  -  -" carry no information and are exactly the
                # noise the indentation was introduced to remove; the names
                # still have to appear, because dropping the parenthetical took
                # away the only other place this job states its scope.
                [ -n "$DG_RD" ] && printf 'D\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_k" "$_s" "$_dn" "$_dv" "$_dr" "$_dd" "$_da" "$_dm" >> "$DG_RD/jobs.tsv"
                if [ "$_dv" = "-" ] && [ -z "$_dt" ]; then
                    _DSBLOCK="$_DSBLOCK$(printf '      %s' "$_s")
"
                else
                    _DSBLOCK="$_DSBLOCK$(printf '      %-52s %10s %6s %8s %8s %10s %8s %8s' "$_s" "$_dn" "" "$_dv" "$_dr" "$_dd" "$_da" "$_dm")
"
                    # Only rows that CARRY a figure contribute to the job total;
                    # a bare-name row has none, and treating its dash as zero is
                    # what turned a prune job into "0.0B".
                fi
            done
            IFS="$_oldifs"
        # The "pozostale" row went with the total column it existed to
        # reconcile. Last/average/worst are not additive -- nobody adds two
        # averages -- so there is nothing left for a remainder to close.
        fi
        # TWO DECIMALS, AND THE TOTAL IS THE MEASUREMENT.
        #
        # Owner, 2026-09-02: "Zrob dwie cyfry po przecinku i zaokraglaj sume i
        # zostaw to. To nie apteka tylko raport." An earlier round derived the
        # job figure from the sum of the PRINTED rows so the column closed to
        # the last digit; at two decimals the residue is under 0.01 of a unit
        # and buying exactness with a number that is not the measurement is a
        # bad trade in a report.
        _vol=$(human_bytes_in "$_vb" "$_u")
        # THE LAST RUN, not the sum over the window. Owner, 2026-09-02:
        # "Naglowek czas laczny jest bez sensu. Ma byc czas ostatni, sredni i
        # maksymalny." Twenty-seven runs add up to a number that says nothing
        # about how long the job takes; last/average/worst is the profile an
        # operator actually reads. A run whose BEGIN fell outside the window
        # has no duration to report and gets a dash rather than a zero.
        if [ "${_ldur:-0}" -ge 0 ]; then _dlast=$(human_secs "$_ldur"); else _dlast="-"; fi
        STATE_BODY="$STATE_BODY$(printf '  %-38s %-17s %10s %6s %8s %8s %10s %8s %8s' "$_disp" "$_st" "$_n" "$_f" "$_vol" "$_rt" "$_dlast" "$_avg"s "$_mx"s)
"
        STATE_BODY="$STATE_BODY$_DSBLOCK"
        # U160: the same row as a record for the relations mail (relations_render).
        case "$nl$SEND_LABELS$nl" in *"$nl$_k$nl"*) _snd=1 ;; *) _snd=0 ;; esac
        [ -n "$DG_RD" ] && printf 'J\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_k" "$_live" "$_n" "$_f" "$_lw" "$_lrc" "${_vb:-0}" "$_vol" "$_rt" "$_dlast" "$_avg" "$_mx" "$_tg" "$_snd" "$_srcs" >> "$DG_RD/jobs.tsv"
    done <<< "$RUN_ROWS"
fi

# Scheduled, but nothing in the window. Listed so it cannot go unnoticed; no
# verdict attached, because a yearly job absent from a week is correct.
if [ -n "$LIVE_LABELS" ]; then
    while IFS= read -r _lk; do
        [ -n "$_lk" ] || continue
        case "$nl$SEEN_LABELS$nl" in *"$nl$_lk$nl"*) continue ;; esac
        _disp=$(printf '%s' "${_lk#profile__*__}" | tr '+' ',')
        [ -n "$DG_RD" ] && printf 'S\t%s\n' "$_lk" >> "$DG_RD/jobs.tsv"
        [ ${#_disp} -gt 38 ] && _disp="${_disp:0:35}..."
        STATE_BODY="$STATE_BODY$(printf '  %-38s %-17s' "$_disp" "brak przebiegu w oknie")
"
    done <<< "$LIVE_LABELS"
fi
if [ -n "$STATE_BAD" ]; then VERDICT="UWAGA"; else VERDICT="OK"; fi

SUBJ="[ZFS] $(zfs_mail_host) $TODAY STAN: $VERDICT -- $N_ALERT alert / $N_WARN warn"
# A quiet report is not a findings mail and must not look like one in a mailbox
# sorted by subject: "0 alert / 0 warn" reads as a verdict that was reached by
# measuring something, which is the one thing this mail did not do.
[ "$QUIET" = "1" ] && SUBJ="[ZFS] $(zfs_mail_host) $TODAY -- cisza, kanal sprawny (raport okresowy)"

# The job-table mail (the layout before U160). Kept whole: it is what goes out when the
# relations mail cannot be built (no python3, no temp dir, a renderer error) -- this mail
# is the host's proof that alerting works, so it must never fail to go out over a layout --
# and on ZFS_DIGEST_LAYOUT=jobs.
jobs_body() {
    # THE PERIOD THE EVENTS COVER, not the moment this mail is sent. `Doba:
    # $TODAY` was the send date, and since this runs at 07:00 over a queue
    # filled the day before, it stamped yesterday's events with today's date.
    # A reader cannot tell a live problem from a repaired one that way.
    # Measured 2026-09-02 on a production pve1: a pool repaired at 17:45
    # the previous day was read as broken this morning, and it was not.
    if [ -n "$MIN_EP" ]; then
        p1=$(date -d "@$MIN_EP" '+%Y-%m-%d %H:%M')
        p2=$(date -d "@$MAX_EP" '+%Y-%m-%d %H:%M')
        if [ "$p1" = "$p2" ]; then PERIOD="$p1"
        elif [ "${p1%% *}" = "${p2%% *}" ]; then PERIOD="$p1 - ${p2##* }"
        else PERIOD="$p1 - $p2"; fi
    else
        PERIOD="$TODAY"
    fi
    printf '%s   %s   STAN: %s\n' "$HOST" "$(date '+%Y-%m-%d %H:%M')" "$VERDICT"
    printf '=====================================================================\n'

    # BLOCK 1 -- NOW. Measured at send time, so a fault repaired since the
    # events below cannot present itself as current.
    printf '\nSTAN BIEZACY -- sprawdzony w tej chwili\n\n'
    # Pools first and outside the table: they are a different kind of fact and
    # do not share its columns. The first cut let them fall under the header,
    # which read as though ONLINE were a job.
    [ -n "$POOL_BODY" ] && printf '%s\n' "$POOL_BODY"
    # THE PERIOD BELONGS TO THE COLUMNS, so it is stated immediately above
    # them. It used to sit under the verdict, past the whole table: the reader
    # met "razem / sredni / najdl." with no idea what they were counted over,
    # and only learned it after the numbers had already been read. Owner,
    # 2026-09-02 -- and the event block below had it right all along, naming
    # its span in its own heading.
    if [ -n "$STATE_BODY" ]; then
        if [ -n "$RUN_WINDOW" ]; then
            printf '  Liczby przebiegow z okresu %s (okno %s dni).\n' "$RUN_WINDOW" "$DIGEST_DAYS"
            printf '  Przyrost = dane DOPISANE na celu (nie bajty na laczu), caly wiersz w jednostce zadania.
'
            # THE DIVISOR HAS TO BE ON THE ROW, or the figure is one the reader must
            # trust. It used to be: a "czas lacz." column sat beside the rate exactly so
            # that przyrost / czas = transfer could be checked by eye. The owner replaced
            # that column with last/avg/max (2026-09-02, and rightly -- a total told
            # nobody whether a run was slow), and this line was left naming a quantity
            # the table no longer prints. Owner, 2026-09-03: "mail w nieaktualnym
            # formacie".
            #
            # Checkability is recovered rather than dropped: avg x count IS the total,
            # and both are on the row.
            printf '  Transfer = przyrost / (czas sr. x przebiegow), czyli przez sumaryczny czas w oknie.
'
            # ONLY WHEN THERE IS SOMETHING TO EXPLAIN.
            #
            # Rendered on pve1: every job there has a single dataset, so the
            # table has no indented rows at all -- and the mail still carried
            # two lines explaining them. Explaining what is not on the page is
            # the same noise as a column of dashes.
            if [ "${HAS_DS_ROWS:-0}" = "1" ]; then
                printf '  Wiersze wciete = datasety zadania; ich czasy to SAM TRANSFER tego datasetu.\n'
                printf '  Kolumny czasu opisuja POJEDYNCZY przebieg: ostatni, sredni i najdluzszy.\n'
            fi
            # The blank line separates the caption block from the table and
            # belongs to the table, not to the caption. Hung off the last
            # caption line it vanished with it, and the header sat flush
            # against the prose on every single-dataset host.
            printf '\n'
        fi
        printf '  %-38s %-17s %10s %6s %8s %8s %10s %8s %8s\n' 'zadanie' 'ostatni przebieg' 'przebiegow' 'bledow' 'przyrost' 'transfer' 'czas ostatni' 'czas sr.' 'czas max'
    fi
    if [ -n "$STATE_BODY" ]; then
        printf '%s' "$STATE_BODY"
        # NAMED WHERE IT HAPPENED, and only when it happened. A skipped run
        # reads as a successful one in the table above -- rc=0, no error -- so
        # the block says outright what the row cannot.
        if [ -n "$SKIP_ROWS" ]; then
            printf '\n  POMINIETE PRZEZ BLOKADE -- inne zadanie trzymalo ten sam dataset:\n'
            printf '%s\n' "$SKIP_ROWS" | while IFS=$'\t' read -r _st _sd; do
                [ -n "$_st" ] || continue
                # The stats file stamps UTC; everything else in this mail is
                # local, and two clocks in one report is how an operator ends
                # up comparing the wrong things.
                _sloc=$(date -d "$_st" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$_st")
                printf '      %-17s %s\n' "$_sloc" "$_sd"
            done
            printf '  Taki przebieg konczy sie rc=0 i w tabeli wyzej wyglada jak udany.\n'
        fi
    else
        printf '  (brak puli ZFS i zadnego cron.log -- nie ma czego zmierzyc)\n'
    fi
    if [ -n "$STATE_BAD" ]; then
        printf '\n  >>> UWAGA:%s\n' "$STATE_BAD"
    else
        printf '\n  >>> WSZYSTKO SPRAWNE W TEJ CHWILI\n'
    fi

    # BLOCK 2 -- what HAPPENED. History, and labelled as such.
    printf '\n---------------------------------------------------------------------\n'
    printf 'ZDARZENIA Z OKRESU %s   (%s)\n' "$PERIOD" "$TOTAL"
    # Said once, plainly: a report of what HAPPENED, not a probe of what is
    # true now. A condition may have been resolved between the event and this
    # mail -- the digest cannot know that, and does not guess.
    printf 'Raport o zdarzeniach ZAKOLEJKOWANYCH w tym okresie -- stan biezacy moze byc juz inny.\n'
    if [ "$N_ALERT" -gt 0 ]; then
        printf '\nALERT -- zadanie padlo, backup przeterminowany albo pula nie jest ONLINE:\n\n%s' "$ALERT_BODY"
    fi
    if [ "$N_WARN" -gt 0 ]; then
        printf '\nWARNING -- starzeje sie, jeszcze nie critical:\n\n%s' "$WARN_BODY"
    fi
    printf '\nPelne logi: %s na %s\n' "${CRON_LOGS# }" "$HOST"
    # The sentence the old one-line heartbeat existed to carry. It is the whole
    # reason a quiet host mails at all, so it travels with the quiet mail and
    # not with the ordinary one -- on a day with findings the mail's arrival is
    # not the news.
    if [ "$QUIET" = "1" ]; then
        printf '\nTen list jest dowodem, ze droga alertu na tym hoscie dziala.\n'
        printf 'Jesli kolejny nie przyjdzie -- to jest alarm.\nKadencja: ZFS_DIGEST_QUIET=%s w /etc/zfs-alert.conf (tam tez ZFS_DIGEST_DAYS -- okno tabeli)\n' "$QUIET_WHEN"
    fi
}

# U157/U159/U160 (owner 2026-11-04): the relations mail. Inputs: the records in DG_RD
# (jobs.tsv, pools.tsv, skip.tsv), the claimed queue, and -- when zfs-backup is there --
# status --json (relation kind) and monitor --json (the current verdict, as F3 shows it).
# Outputs in DG_RD: mail.eml (MIME, text + HTML attachment), subject.ascii, body.ascii.
digest_zb() {
    local z="${ZFS_DIGEST_ZB:-}"
    [ -n "$z" ] || z=$(command -v zfs-backup 2>/dev/null)
    [ -n "$z" ] || { [ -x /usr/local/bin/zfs-backup ] && z=/usr/local/bin/zfs-backup; }
    [ -n "$z" ] && [ "$z" != none ] && printf '%s' "$z"
}
relations_render() {
    local zb
    zb=$(digest_zb)
    if [ -n "$zb" ]; then
        # The exit status is not read: monitor --json exits with the worst verdict (2 =
        # CRITICAL) and still prints the whole document; a broken one fails to parse and
        # the renderer goes on without it. --foreground: without it the verb, run in a
        # background process group, printed nothing (measured on pve11).
        timeout --foreground 120 "$zb" status --json > "$DG_RD/status.json" 2>/dev/null
        timeout --foreground 300 "$zb" monitor --json > "$DG_RD/monitor.json" 2>/dev/null
    fi
    printf '%s\n' "$SKIP_ROWS" > "$DG_RD/skip.tsv"
    DG_HOST="$HOST" DG_LABEL="$(zfs_mail_host)" DG_SENDER="$(zfs_mail_sender)" DG_DAYS="$DIGEST_DAYS" DG_QUEUE="$PROCESSING" DG_QUIET="${QUIET:-0}" \
    DG_QUIET_WHEN="$QUIET_WHEN" DG_TO="${ZFS_ALERT_EMAIL:-root}" DG_FROM="$(id -un 2>/dev/null || echo root)@$HOST" \
    DG_LOGS="${CRON_LOGS# }" DG_WINDOW="${RUN_WINDOW:-}" DG_RD="$DG_RD" python3 - <<'PYEOF'
import os, re, json, html, time, gzip, textwrap
from email.message import EmailMessage
from email.utils import formatdate

E = os.environ
RD = E["DG_RD"]
HOST = E.get("DG_HOST", "?")
SHORT = HOST.split(".")[0]
# alerts.site (zfs_mail_host): "<site> <host>", or the full host name -- what the reader sees
LABEL = E.get("DG_LABEL") or HOST
DAYS = int(E.get("DG_DAYS") or 7)
NOW = time.localtime()

def rd(name):
    try:
        with open(os.path.join(RD, name), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""

def js(name):
    try:
        return json.loads(rd(name) or "null")
    except ValueError:
        return None

# --- words: the GUI's (tui/zfs-tui.py VERDICTS, rel_type), never the cron label's ---
TIER_F = {"hourly": "godzinowa", "daily": "dobowa", "weekly": "tygodniowa",
          "monthly": u"miesięczna", "yearly": "roczna", "annual": "roczna"}
TIER_M = {"hourly": "godzinowy", "daily": "dobowy", "weekly": "tygodniowy",
          "monthly": u"miesięczny", "yearly": "roczny", "annual": "roczny"}
REL_RE = re.compile(r"^(?:\S+ )?profile__relacja-(.+?)__(\S+) (.+?)(?: \((.*)\))?$")
ANY_RE = re.compile(r"^(?:\S+ )?(?:profile__.+?__)?(\S+) (.+?)(?: \((.*)\))?$")

def tier_of(t):
    base = (t or "").split("_")[-1]
    side = u" (źródło)" if re.match(r"^(l?src)_", t or "") else ""
    return base, side

def parse_label(k):
    """-> relation name (None for a job of no relation), task words, tier base."""
    k = re.sub(r" -- .*$", "", k)
    m = REL_RE.match(k)
    if m:
        rel, tier, word, scope = m.group(1), m.group(2), m.group(3), m.group(4)
    else:
        m = ANY_RE.match(k)
        if not m:
            return None, k, "", k
        rel, tier, word, scope = None, m.group(1), m.group(2), m.group(3)
    base, side = tier_of(tier)
    f, mm = TIER_F.get(base, base), TIER_M.get(base, base)
    # A snapshot is always made on the source, so only the prune says which side it cleans.
    if word == "snapshot":
        task = "migawka " + f
    elif word == "backup":
        task = "kopia " + f
    elif word == "prune":
        task = "czyszczenie, szczebel " + mm + side
    elif word in ("stale", "getting stale", "monitor BROKEN"):
        task = "monitor, szczebel " + mm
    else:
        task = tier + " " + word
    return rel, task, base, (scope or "").replace("+", ", ")

def kind_of(r):
    mode = r.get("mode") or ""
    if mode == "local":
        k = "kopia lokalna" if (r.get("client_target") or r.get("landing")) else "migawki lokalne"
    else:
        k = {"sync": "lustro", "snaponly": "migawki zdalne"}.get(mode, mode or "backup")
    if str(r.get("passive") or "").lower() in ("1", "yes", "true"):
        k += ", pasywna"
    return k

def when(s):
    m = re.search(r"(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)", s or "")
    return "%s.%s %s:%s" % (m.group(3), m.group(2), m.group(4), m.group(5)) if m else (s or "-")

def human(b):
    for u, d in (("T", 1 << 40), ("G", 1 << 30), ("M", 1 << 20), ("K", 1 << 10)):
        if b >= d:
            return "%.1f%s" % (b / float(d), u)
    return "%dB" % b

def cls(j):
    if j["rc"] not in ("0", "8", ""):
        return "err"
    return "warn" if j["rc"] == "8" or j["f"] else ""

def plural(n, one, few, many):
    if n == 1:
        return one
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return few
    return many

# --- relations ---
rels = {}
def rel(name):
    return rels.setdefault(name, {"name": name, "kind": "-", "jobs": [], "mons": [], "idle": []})

for r in ((js("status.json") or {}).get("relations") or []):
    if r.get("state") in ("removed", "deleted"):
        continue
    x = rel(r.get("name"))
    x["kind"] = kind_of(r)
    if r.get("paused_local") or r.get("disabled"):
        x["paused"] = True

jobs = {}
for ln in rd("jobs.tsv").splitlines():
    f = ln.split("\t")
    if f[0] == "J" and len(f) >= 15:
        if f[2] != "1":
            continue    # not in cron any more: a deleted relation is not shown (U160 point 3)
        relname, task, base, scope = parse_label(f[1])
        j = {"k": f[1], "n": int(f[3] or 0), "f": int(f[4] or 0), "lw": f[5], "rc": f[6],
             "vb": int(f[7]) if f[7].isdigit() else 0, "vol": f[8], "rate": f[9], "dlast": f[10],
             "avg": f[11], "max": f[12], "tg": f[13], "send": f[14] == "1", "task": task,
             "tier": base, "scope": scope, "ds": [], "err": "",
             "srcs": [x for x in (f[15] if len(f) > 15 else "").split(",") if x]}
        jobs[f[1]] = j
        rel(relname or scope or task)["jobs"].append(j)
    elif f[0] == "D" and len(f) >= 9 and f[1] in jobs:
        jobs[f[1]]["ds"].append(f[2:9])
    elif f[0] == "S" and len(f) >= 2:
        relname, task, base, scope = parse_label(f[1])
        rel(relname or scope or task)["idle"].append(task + (" (" + scope + ")" if scope and relname else ""))

# A relation with no copy has one side only: "(źródło)" on its prune says nothing there.
for x in rels.values():
    if not any(j["send"] and j["tg"] for j in x["jobs"]):
        for j in x["jobs"]:
            j["task"] = j["task"].replace(u" (źródło)", "")
TASK_ORDER = ("migawka", "kopia", "czyszczenie", "monitor")
def task_key(j):
    return (cls(j) != "err", [i for i, w in enumerate(TASK_ORDER) if j["task"].startswith(w)][:1] or [9], j["task"])

RANK = {"OK": 0, "CZEKA": 1, "WAITING": 1, "WARNING": 3, "UNKNOWN": 4, "CRITICAL": 5}
for m in ((js("monitor.json") or {}).get("monitors") or []):
    if m.get("label"):
        rel(m["label"])["mons"].append(m)

# The last error line of a failed job: the detail the job queued (daily alert mode).
events = []
try:
    with open(E.get("DG_QUEUE", ""), encoding="utf-8", errors="replace") as fq:
        qlines = fq.read().splitlines()
except OSError:
    qlines = []
for ln in qlines:
    f = ln.split("\t", 3)
    if len(f) < 3:
        continue
    det = [x.strip() for x in (f[3] if len(f) > 3 else "").split("\x01") if x.strip()]
    events.append((f[0], f[1], f[2], det))
    key = re.sub(r"^\S+ (?=profile__)", "", f[2])
    if key in jobs and det:
        jobs[key]["err"] = det[-1]

# THE CAUSE (owner, variant A 2026-11-04: "nie mówi o szczegółach, co wysiadło"). zfs-job.sh
# appends the job's stderr to its cron.log right before "ZFS-JOB END <host> <label> rc=N"
# (zfs-job.sh: cat "$e" >>"$LOG"), so the lines between the previous ZFS-JOB marker and a
# failed END are that run's own error -- there even when no queue holds a detail (alerts
# sent immediately). The queued detail above stays the fallback.
STAMP = re.compile(r"^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d\S*\s+(-\s+)?")
def log_causes(keys):
    found = {}
    files = [f for f in (E.get("DG_LOGS") or "").split() if os.path.isfile(f)]
    for fn in sorted(files, key=lambda f: os.path.getmtime(f)):
        try:
            fh = gzip.open(fn, "rt", encoding="utf-8", errors="replace") if fn.endswith(".gz") \
                else open(fn, encoding="utf-8", errors="replace")
        except OSError:
            continue
        block = []
        with fh:
            for ln in fh:
                ln = ln.rstrip("\n")
                m = re.search(r" ZFS-JOB (BEGIN|END) \S+ (.*?)(?: rc=(\d+))?$", ln)
                if not m:
                    if ln.strip():
                        block.append(ln.strip())
                    continue
                if m.group(1) == "END" and m.group(2) in keys and m.group(3) not in (None, "0"):
                    lines = [STAMP.sub("", x) for x in block if not x.startswith(("CRITICAL ", "WARNING ", "OK "))]
                    # rc=8: the last line only says the run was DEGRADED; the reason (and the
                    # fix) is the FIRST "Quiesce:" line of the run (measured on pve11).
                    q = [x for x in lines if x.startswith("Quiesce:")] if m.group(3) == "8" else []
                    if q or lines:
                        c = (q or lines[-1:])[0]
                        found[m.group(2)] = c if len(c) <= 320 else c[:317] + "..."
                block = []
    return found
for k, c in log_causes(set(k for k, j in jobs.items() if j["rc"] not in ("0", ""))).items():
    jobs[k]["err"] = c

def obj(j):
    """What the job acts on, as zfs list names it: the sources (siblings shortened), -> target."""
    out = []
    for i, d in enumerate(j["srcs"]):
        if i and d.rsplit("/", 1)[0] == j["srcs"][0].rsplit("/", 1)[0]:
            d = d.rsplit("/", 1)[-1]
        out.append(d)
    o = ", ".join(out) or j["scope"] or "-"
    return o + (" -> " + j["tg"] if j["send"] and j["tg"] else "")

def wrap(prefix, text, width=78, more=0):
    return textwrap.wrap(text, width, initial_indent=prefix, subsequent_indent=" " * (len(prefix) + more),
                         break_long_words=False, break_on_hyphens=False) or [prefix.rstrip()]

def distinct_causes(js_):
    seen, out = set(), []
    for j in js_:
        if j["err"]:
            k = re.sub(r"'[^']*'", "''", j["err"])
            if k not in seen:
                seen.add(k)
                out.append(j["err"])
    return out

def n_tasks(n):
    return u"%d %s" % (n, "zadania" if n == 1 else u"zadań")

# --- verdict per relation, in the GUI's words ---
def mon_tier(m):
    return (m.get("pattern") or "").rstrip("_").split("_")[-1]

def first_line(s, key):
    for l in (s or "").splitlines():
        if l.strip().startswith(key):
            return l.strip()
    return ((s or "").strip().splitlines() or [""])[0]

todo = []
for x in rels.values():
    live = x["jobs"]
    bad = [j for j in live if j["rc"] not in ("0", "8", "")]
    deg = [j for j in live if j["rc"] == "8"]
    mons = sorted(x["mons"], key=lambda m: -RANK.get(m.get("verdict"), 2))
    worst = mons[0] if mons else None
    wv = worst.get("verdict") if worst else None
    okj = [j for j in live if j["rc"] in ("0", "8") and not j["task"].startswith(("czyszczenie", "monitor"))]
    x["newest"] = max((j["lw"] for j in okj), default="")
    if not x["newest"]:
        # No run of the window succeeded: the newest snapshot the monitor saw, if any.
        seen = [re.search(r"newest=\S*?(\d{4}-\d\d-\d\d)_(\d\d)-(\d\d)", m.get("reason") or "") for m in mons]
        x["newest"] = max(("%s %s:%s" % g.groups() for g in seen if g), default="")
    x["runs"] = sum(j["n"] for j in live)
    x["fails"] = sum(j["f"] for j in live)
    if bad:
        x["rank"], x["state"] = 9, u"błąd biegu (%d z %s)%s" % (len(bad), n_tasks(len(live)),
                                                             ", stare" if wv == "CRITICAL" else "")
        bad.sort(key=lambda j: j["lw"], reverse=True)
        verb = u"zadanie kończy się" if len(bad) == 1 else (u"zadania kończą się" if plural(len(bad), 1, 2, 3) == 2 else u"zadań kończy się")
        lines = []
        for j in bad[:3]:
            lines.extend(wrap("", u"%s, %s rc=%s: %s" % (j["task"], when(j["lw"]), j["rc"], obj(j)), 75, 2))
        if len(bad) > 3:
            lines.append(u"... (jeszcze %d)" % (len(bad) - 3))
        causes = distinct_causes(bad)
        for c in causes[:2]:
            lines.extend(wrap(u"przyczyna: ", c, 75))
        if len(causes) > 2:
            lines.append(u"(i %d innych przyczyn -- załącznik)" % (len(causes) - 2))
        todo.append((9, x["name"], u"%d %s błędem" % (len(bad), verb), lines,
                     u"sprawdź: zfs-backup gui -> F2 (przebiegi)"))
    elif wv == "CRITICAL":
        r = first_line(worst.get("reason"), "CRITICAL")
        a = re.search(r"age=(\S+)", r)
        x["rank"], x["state"] = 8, "stare: " + TIER_F.get(mon_tier(worst), mon_tier(worst))
        todo.append((8, x["name"], u"najnowsza %s sprzed %s (alarm po %s)" % (
                     TIER_F.get(mon_tier(worst), mon_tier(worst)), a.group(1) if a else "?", worst.get("crit") or "?"),
                     [r], u"sprawdź: zfs-backup gui -> F3"))
    elif wv == "UNKNOWN":
        x["rank"], x["state"] = 7, "nie odpowiada"
        todo.append((7, x["name"], "monitor nie odpowiada", [first_line(worst.get("reason"), "")], ""))
    elif deg:
        x["rank"], x["state"] = 6, u"bez zamrożenia (%d z %s)" % (len(deg), n_tasks(len(live)))
        tasks = sorted(set(j["task"] for j in deg))
        last = max(j["lw"] for j in deg)
        what = (u"%s bez zamrożenia gościa, %s rc=8" % (tasks[0], when(last))) if len(tasks) == 1 \
            else (u"%s bez zamrożenia gościa, ostatnio %s rc=8" % (n_tasks(len(deg)).replace("zadania", "zadanie"), when(last)))
        lines = wrap("", ", ".join(obj(j) for j in deg), 75)
        lines.append(u"migawka jest, ale spójna jak po nagłym wyłączeniu gościa")
        causes = distinct_causes(deg)
        for c in causes[:2]:
            lines.extend(wrap(u"przyczyna: ", c, 75))
        todo.append((6, x["name"], what, lines,
                     u"" if causes else u"powód w logu biegu (F2): np. agent gościa niedostępny albo konto bez dostępu do gości"))
    elif wv == "WARNING":
        x["rank"], x["state"] = 5, u"spóźnione: " + TIER_F.get(mon_tier(worst), mon_tier(worst))
    elif x.get("paused"):
        x["rank"], x["state"] = 2, "wstrzymana"
    elif wv in ("CZEKA", "WAITING") or (not live and not mons):
        x["rank"], x["state"] = 1, "czeka na pierwszy termin"
    else:
        x["rank"], x["state"] = 0, "aktualne"

pools = []
for ln in rd("pools.tsv").splitlines():
    f = ln.split()
    if len(f) >= 3:
        pools.append(f[:3])
        cap = int(re.sub(r"\D", "", f[2]) or 0)
        if f[1] != "ONLINE" or cap >= 80:
            todo.append((10, "pula " + f[0], u"%s, zajęte %s" % (f[1], f[2]), [],
                         u"sprawdź: zpool status %s" % f[0]))
todo.sort(key=lambda t: (-t[0], t[1]))

order = sorted(rels.values(), key=lambda x: (-x["rank"], x["name"]))
N = len(order)
K = sum(1 for x in order if x["rank"] >= 5)
pool_bad = [p for p in pools if p[1] != "ONLINE" or int(re.sub(r"\D", "", p[2]) or 0) >= 80]
day = time.strftime("%d.%m", NOW)
if K == 0 and not pool_bad:
    subj = u"[ZFS] %s %s: OK, %d %s" % (LABEL, day, N, plural(N, "relacja", "relacje", "relacji"))
else:
    parts = []
    if K:
        parts.append(u"%d z %d relacji wymaga uwagi" % (K, N))
    for p in pool_bad:
        parts.append("pula %s %s %s" % (p[0], p[1], p[2]))
    subj = u"[ZFS] %s %s: %s" % (LABEL, day, ", ".join(parts))
if E.get("DG_QUIET") == "1":
    subj += u" (raport okresowy)"

# --- text body, 78 columns ---
out = []
out.append(u"%s  %s   pule: %s" % (LABEL, time.strftime("%Y-%m-%d %H:%M", NOW),
           "   ".join("%s %s %s" % tuple(p) for p in pools) or "brak"))
out.append("")
w = min(max([len(x["name"]) for x in order] + [7]), 30)
def cut(s, n):
    return s if len(s) <= n else s[:n - 3] + "..."
# Variant A (owner 2026-11-04): no kind column -- "migawki lokalne" told migawki-a from
# migawki-b nothing; what tells relations apart is in DO ZROBIENIA and in the attachment.
out.append("%-*s  %-11s  %s" % (w, "RELACJA", "NAJNOWSZA", "STAN"))
out.append("%s  %s  %s" % ("-" * w, "-" * 11, "-" * max(4, 74 - w - 13)))
for x in order:
    out.append(u"%-*s  %-11s  %s" % (w, cut(x["name"], w), when(x["newest"]) if x["newest"] else "-", x["state"]))
if not order:
    out.append(u"(brak relacji i zadań na tym hoście)")
if todo:
    out.append("")
    out.append("DO ZROBIENIA")
    for i, (_, who, what, lines, hint) in enumerate(todo, 1):
        out.append(u"%d. %s -- %s" % (i, who, what))
        for l in lines:
            out.append("   " + l)
        if hint:
            out.append("   " + hint)
runs = sum(x["runs"] for x in order)
fails = sum(x["fails"] for x in order)
frel = sum(1 for x in order if x["fails"])
copies = [j for x in order for j in x["jobs"] if j["send"] and j["tg"]]
vol = sum(j["vb"] for j in copies)
span = u"Tydzień" if DAYS == 7 else u"Ostatnie %d dni" % DAYS
out.append("")
# "dopisane" only where something is copied: on a host of snapshots only it is always 0B.
out.append(u"%s: %d %s, %d %s%s%s." % (
    span, runs, plural(runs, "bieg", "biegi", u"biegów"), fails, plural(fails, u"błąd", u"błędy", u"błędów"),
    (" (%d %s)" % (frel, plural(frel, "relacja", "relacje", "relacji"))) if frel else "",
    (", dopisane %s" % human(vol)) if copies else ""))
fname = "statystyka-%s-%s.html" % (SHORT, time.strftime("%Y-%m-%d", NOW))
out.append(u"Pełna statystyka: załącznik %s." % fname)
if E.get("DG_QUIET") == "1":
    out.append("")
    out.append(u"Ten list jest dowodem, że droga alertu na tym hoście działa.")
    out.append(u"Jeśli kolejny nie przyjdzie -- to jest alarm.")
    out.append(u"Kadencja: ZFS_DIGEST_QUIET=%s w /etc/zfs-alert.conf." % E.get("DG_QUIET_WHEN", ""))
body = "\n".join(out) + "\n"

# --- the attachment: dark, monospace, one section per relation (palette in C) ---
C = {"bg": "#101418", "fg": "#d8dee4", "dim": "#8b949e", "line": "#3a4450", "head": "#1c232b",
     "err": "#ff6b6b", "errbg": "#3a1a1a", "warn": "#f2c14e", "warnbg": "#332a10", "acc": "#5fb3d9"}
h = html.escape
rows = []
for x in order:
    rows.append(u'<h2>&#9656; %s <span class="dim">(%s)</span><span class="sum">%d %s, %d %s</span></h2>' % (
        h(x["name"]), h(x["kind"]), x["runs"], plural(x["runs"], "bieg", "biegi", u"biegów"),
        x["fails"], plural(x["fails"], u"błąd", u"błędy", u"błędów")))
    rows.append(u"<p class='st'>stan: %s</p>" % h(x["state"]))
    if x["jobs"]:
        rows.append(u"<table><tr><th>zadanie</th><th>obiekt</th><th>ostatni bieg</th><th>biegów</th><th>błędy</th>"
                    u"<th>dopisane</th><th>transfer</th><th>czas ost.</th><th>śr.</th><th>max</th><th>ostatni błąd</th></tr>")
        for j in sorted(x["jobs"], key=task_key):
            copy = j["send"] and bool(j["tg"])
            rows.append(u"<tr class='%s'><td>%s</td><td class='o'>%s</td><td>%s</td><td>%d</td><td>%d</td><td>%s</td><td>%s</td>"
                        u"<td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
                cls(j), h(j["task"]), h(obj(j)),
                h(when(j["lw"])) + ("" if j["rc"] in ("0", "") else " rc=" + h(j["rc"])), j["n"], j["f"],
                h(j["vol"]) if copy else "-", h(j["rate"]) if copy else "-", h(j["dlast"]),
                h(j["avg"]) + "s", h(j["max"]) + "s", h(j["err"]) if cls(j) == "err" else ""))
            if copy:
                for d in j["ds"]:
                    rows.append(u"<tr class='ds'><td></td><td class='o'>&nbsp;&nbsp;%s</td><td></td><td>%s</td><td></td><td>%s</td>"
                                u"<td>%s</td><td>%s</td><td>%s</td><td>%s</td><td></td></tr>" % tuple(h(v) for v in (d[0], d[1], d[2], d[3], d[4], d[5], d[6])))
        rows.append("</table>")
    if x["idle"]:
        rows.append(u"<p class='warn'>bez biegu w oknie: %s</p>" % h(", ".join(x["idle"])))
if events:
    rows.append(u"<h2>Zdarzenia z okresu</h2><table><tr><th>kiedy</th><th>rodzaj</th><th>zadanie</th><th>ostatnia linia</th></tr>")
    for ep, sev, job, det in events:
        try:
            t = time.strftime("%d.%m %H:%M", time.localtime(int(ep)))
        except ValueError:
            t = ep
        relname, task, base, scope = parse_label(job)
        rows.append(u"<tr class='%s'><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % (
            "err" if sev == "ALERT" else "warn", h(t), "alarm" if sev == "ALERT" else u"ostrzeżenie",
            h((relname + ": " if relname else "") + task), h(det[-1] if det else "")))
    rows.append("</table>")
skips = [l.split("\t") for l in rd("skip.tsv").splitlines() if l.strip()]
if skips:
    rows.append(u"<h2>Pominięte przez blokadę</h2><p class='dim'>inne zadanie trzymało ten sam dataset; "
                u"taki bieg kończy się rc=0</p><table>")
    for s in skips:
        rows.append(u"<tr><td>%s</td><td>%s</td></tr>" % (h(when(s[0])), h(s[1] if len(s) > 1 else "")))
    rows.append("</table>")
page = u"""<!doctype html><html lang="pl"><head><meta charset="utf-8"><title>%(t)s</title><style>
body{background:%(bg)s;color:%(fg)s;font:13px/1.45 Consolas,'DejaVu Sans Mono',monospace;margin:16px}
h1{font-size:15px;border:1px solid %(line)s;background:%(head)s;padding:6px 10px;margin:0 0 12px}
h2{font-size:14px;color:%(acc)s;margin:18px 0 4px}.sum{float:right;color:%(dim)s;font-weight:normal}
.dim{color:%(dim)s}.st{margin:0 0 6px;color:%(dim)s}
table{border-collapse:collapse;width:100%%;margin-bottom:6px}
th,td{border:1px solid %(line)s;padding:2px 8px;text-align:left;white-space:nowrap}
th{background:%(head)s;color:%(dim)s;font-weight:normal}td+td{text-align:right}td:last-child{text-align:left;white-space:normal}
tr.err td{color:%(err)s;background:%(errbg)s}tr.warn td,p.warn{color:%(warn)s}tr.warn td{background:%(warnbg)s}
tr.ds td{color:%(dim)s}td.o{text-align:left;white-space:normal}
</style></head><body><h1>%(t)s<span class="sum">pule: %(p)s</span></h1>%(r)s
<p class="dim">okno: %(win)s (%(d)d dni); logi: %(logs)s</p></body></html>""" % dict(
    C, t=h(u"%s -- statystyka biegów" % LABEL), p=h("   ".join("%s %s %s" % tuple(p) for p in pools)),
    r="\n".join(rows), win=h(E.get("DG_WINDOW") or "-"), d=DAYS, logs=h(E.get("DG_LOGS") or "-"))

msg = EmailMessage()
msg["Subject"] = subj
msg["From"] = "zfs-backup %s <%s>" % (E.get("DG_SENDER") or SHORT, E.get("DG_FROM", "root"))
msg["To"] = E.get("DG_TO", "root")
msg["Date"] = formatdate(localtime=True)
msg.set_content(body)
msg.add_attachment(page, subtype="html", charset="utf-8", filename=fname)
with open(os.path.join(RD, "mail.eml"), "wb") as f:
    f.write(msg.as_bytes())

# ASCII copies for "mail -s" when there is no sendmail (bsd-mailx sends what it is given).
FOLD = dict(zip(u"ąćęłńóśźżĄĆĘŁŃÓŚŹŻ", "acelnoszzACELNOSZZ"))
def fold(s):
    return "".join(FOLD.get(c, c) for c in s).encode("ascii", "replace").decode("ascii")
with open(os.path.join(RD, "subject.ascii"), "w") as f:
    f.write(fold(subj))
with open(os.path.join(RD, "body.ascii"), "w") as f:
    f.write(fold(body.replace(u"Pełna statystyka: załącznik %s." % fname,
                              u"(Bez załącznika: na hoście nie ma sendmail.)")))
PYEOF
}
digest_send() {
    if [ "${ZFS_DIGEST_LAYOUT:-relacje}" != jobs ] && [ -n "$DG_RD" ] \
       && command -v python3 >/dev/null 2>&1 && relations_render 2>"$DG_RD/render.err"; then
        local sm; sm=$(alert_sendmail)
        if [ -n "$sm" ]; then
            "$sm" -t -oi < "$DG_RD/mail.eml"
        else
            mail -s "$(cat "$DG_RD/subject.ascii")" "${ZFS_ALERT_EMAIL:-root}" < "$DG_RD/body.ascii"
        fi
        return
    fi
    # The renderer failed: say so where cron collects stderr, and send the old mail.
    [ -s "${DG_RD:-/nonexistent}/render.err" ] && sed 's/^/alert-digest.sh: relations mail: /' "$DG_RD/render.err" | tail -5 >&2
    jobs_body | mail -s "$SUBJ" "${ZFS_ALERT_EMAIL:-root}"
}

if digest_send; then
    rm -f "$PROCESSING"
else
    # Mail failed (no MTA, relay refused, mailutils missing). Put the findings
    # back so the next run retries them: this is the ONLY copy, and the whole
    # point of a once-a-day digest is that a lost run is a lost DAY of alerting.
    # Deleting on failure is what the v1 digest did, and it silently discarded
    # everything queued whenever delivery broke.
    (umask 0002; cat "$PROCESSING" >> "$QUEUE") 2>/dev/null && rm -f "$PROCESSING"
    # A quiet report that could not be sent is the failure the whole quiet-mail
    # arrangement exists to expose, so it must not be reported as "0 findings
    # requeued" -- which reads like nothing was lost.
    if [ "$QUIET" = "1" ]; then
        echo "alert-digest.sh: quiet report could not be sent -- the alert channel on this host is NOT proven" >&2
    else
        echo "alert-digest.sh: mail delivery failed -- $TOTAL finding(s) requeued for the next run" >&2
    fi
    exit 1
fi
