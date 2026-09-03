#!/bin/bash
# check-pool-capacity.sh v7 -- warns before a zpool, or a dataset with a refquota,
# fills up. Catches slow exhaustion BEFORE it turns into a failed job.
#
# It reports through notify-fail.sh rather than mailing directly. Sending its
# own mail made it the one thing on the host that ignored the one-mail-per-day
# rule, and at fleet scale a second channel is a second thing to start
# filtering. Going through the queue also means the finding arrives with its
# numbers attached, in the same digest as everything else.
# Usage in cron: 0 8 * * * /root/scripts/check-pool-capacity.sh
THRESHOLD=90
HOST=$(hostname -f 2>/dev/null || hostname)
NOTIFY="${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"

alert() {
    if [ -x "$NOTIFY" ]; then
        "$NOTIFY" "$1" "$2"
    else
        # No notify-fail.sh to hand the finding to: mail it directly, to the
        # address zfs-alert.conf names (read through alert-env.sh, installed
        # beside this script), root if neither is there.
        # shellcheck disable=SC1091
        . "$(dirname "$0")/alert-env.sh" 2>/dev/null || :
        echo "$2" | mail -s "[ZFS CAPACITY] $1" "${ZFS_ALERT_EMAIL:-root}"
    fi
}

# THE PROBE IS ENUMERATED ONCE, AND ITS FAILURE IS A FINDING.
#
# `for pool in $(zpool list -H -o name)` runs its body zero times when the
# enumeration fails, so the script says nothing -- and nothing is exactly what
# it says when every pool is healthy. "I could not look" then arrives at the
# operator as "I looked and all is well", which is the one failure mode this
# whole file exists to prevent (pve1's rpool sat DEGRADED for weeks because
# health was checked nowhere; a check that cannot fail loudly is checked
# nowhere too).
#
# Three outcomes, three different things to say:
#   rc != 0        the probe itself failed -- report it, and do not run either
#                  loop, because there is no list to loop over;
#   rc == 0, empty a host running this package with ZERO imported pools is not
#                  "nothing to check", it is a host whose storage is gone;
#   rc == 0, list  proceed.
POOLS=$(zpool list -H -o name 2>&1)
POOLS_RC=$?
if [ "$POOLS_RC" -ne 0 ]; then
    alert "sonda pul na ${HOST} PADLA (rc=${POOLS_RC})" \
          "'zpool list -H -o name' zakonczylo sie kodem ${POOLS_RC} na ${HOST}, wiec ani pojemnosc, ani stan pul NIE zostaly sprawdzone w tym przebiegu.
Brak alertu o pulach w tym cyklu nie oznacza, ze pule sa zdrowe -- oznacza, ze nikt ich nie widzial.

${POOLS}"
    POOLS=""
elif [ -z "${POOLS//[[:space:]]/}" ]; then
    alert "ZERO pul ZFS na ${HOST}" \
          "'zpool list -H -o name' nie zwrocilo ani jednej puli na ${HOST}. Na hoscie z zainstalowanym tym pakietem to nie jest cisza do zignorowania -- to znaczy, ze zadna pula nie jest zaimportowana."
    POOLS=""
fi

# THE PROBE SUCCEEDED IS NOT THE SAME QUESTION AS THE OUTPUT LOOKS RIGHT.
#
# No pipe here on purpose: `zpool list ... | tr -d '%'` reports tr's status,
# not zpool's, so "42%" printed by a command that then exited non-zero read as
# a clean measurement. The % is stripped by parameter expansion instead, and rc
# is captured from the probe itself before anything else can overwrite it.
for pool in $POOLS; do
    cap_raw=$(zpool list -H -o capacity "$pool" 2>/dev/null)
    cap_rc=$?
    cap=${cap_raw%%%}
    if [ "$cap_rc" -ne 0 ]; then
        alert "sonda pojemnosci puli '${pool}' na ${HOST} PADLA (rc=${cap_rc})" \
              "'zpool list -H -o capacity ${pool}' zakonczylo sie kodem ${cap_rc} na ${HOST}, wiec zapelnienie tej puli NIE zostalo sprawdzone -- niezaleznie od tego, co zdazylo wypisac ('${cap_raw}')."
        continue
    fi
    case "$cap" in
        ''|*[!0-9]*)
            # Same disease as the enumeration: an unreadable capacity used to
            # produce a shell error on stderr and no finding at all.
            alert "nie odczytano pojemnosci puli '${pool}' na ${HOST}" \
                  "'zpool list -H -o capacity ${pool}' nie zwrocilo liczby na ${HOST}, wiec zapelnienie tej puli NIE zostalo sprawdzone." ;;
        *)
            if [ "$cap" -ge "$THRESHOLD" ]; then
                alert "pula '${pool}' na ${HOST}: ${cap}%" \
                      "Pula '${pool}' na ${HOST} jest zapelniona w ${cap}% (prog: ${THRESHOLD}%)."
            fi ;;
    esac
done

# IMPORTANT: compare against 'referenced', not 'used' -- 'used' includes all
# retained snapshots and will read as 100%+ even when the live filesystem
# itself has headroom, because refquota only constrains 'referenced'.
zfs list -Hp -o name,referenced,refquota -t filesystem | while IFS=$'\t' read -r name referenced refquota; do
    [ "$refquota" = "0" ] && continue
    pct=$(( referenced * 100 / refquota ))
    if [ "$pct" -ge "$THRESHOLD" ]; then
        alert "dataset '${name}' na ${HOST}: ${pct}%" \
              "Dataset '${name}' na ${HOST} wykorzystuje ${pct}% swojego refquota (prog: ${THRESHOLD}%)."
    fi
done

# POOL HEALTH (v4). Capacity was checked daily; HEALTH was checked nowhere in
# the whole estate, and it showed: pve1's rpool sat DEGRADED for weeks with a
# working backup chain and not one alert, because a degraded pool still
# transfers fine -- right up until the second disk goes. Anything != ONLINE is
# a finding, with the zpool status detail attached so the digest names the
# device instead of making the operator ssh in to ask.
# $POOLS, not a second enumeration: one probe, one failure report. And an
# unreadable HEALTH is a finding of its own -- the previous shape tested
# `[ -n "$health" ]` and fell silent on an empty answer, so a pool whose state
# could not be read looked exactly like a pool that is ONLINE.
for pool in $POOLS; do
    health=$(zpool list -H -o health "$pool" 2>/dev/null)
    health_rc=$?
    if [ "$health_rc" -ne 0 ]; then
        # rc BEFORE content: a probe that printed ONLINE and then failed has
        # not established that the pool is ONLINE. Trusting the string would
        # let the single most reassuring word on the host be produced by a
        # command that did not work.
        alert "sonda stanu puli '${pool}' na ${HOST} PADLA (rc=${health_rc})" \
              "'zpool list -H -o health ${pool}' zakonczylo sie kodem ${health_rc} na ${HOST}, wiec stan tej puli NIE zostal sprawdzony -- niezaleznie od tego, co zdazylo wypisac ('${health}')."
    elif [ -z "$health" ]; then
        alert "nie odczytano stanu puli '${pool}' na ${HOST}" \
              "'zpool list -H -o health ${pool}' nie zwrocilo nic na ${HOST}, wiec stan tej puli NIE zostal sprawdzony.
Brak alertu o tej puli w tym cyklu nie oznacza ONLINE."
    elif [ "$health" != "ONLINE" ]; then
        detail=$(zpool status "$pool" 2>/dev/null | head -n 20)
        alert "pula '${pool}' na ${HOST}: ${health}"               "Pula '${pool}' na ${HOST} ma stan ${health} (oczekiwany: ONLINE).

${detail}"
    fi
done

# STALLED TRANSFERS (v4). The engines keep one live-progress record per running
# transfer (/var/lib/zfs-snapshot-all/progress, built 2026-08-23 exactly so a
# monitor can consume it). A record still marked "running" whose watcher
# stopped refreshing it means the transfer died, hung, or was killed -- and
# nothing else reports that: the job's own alert fires only when the job EXITS
# non-zero, which a hung pipeline never does. 30 minutes without a heartbeat on
# a record that refreshes every 2 seconds is not lag; it is a corpse.
PROG_DIR="${ZFS_PROGRESS_DIR:-/var/lib/zfs-snapshot-all/progress}"
NOW=$(date +%s)
if [ -d "$PROG_DIR" ]; then
    for f in "$PROG_DIR"/*.json; do
        [ -e "$f" ] || continue
        grep -q '"state":"running"' "$f" 2>/dev/null || continue
        upd=$(sed -n 's/.*"updated_epoch":\([0-9]*\).*/\1/p' "$f")
        case "$upd" in ''|*[!0-9]*) continue ;; esac
        age=$(( NOW - upd ))
        if [ "$age" -ge 1800 ]; then
            ds=$(sed -n 's/.*"dataset":"\([^"]*\)".*/\1/p' "$f")
            lb=$(sed -n 's/.*"label":"\([^"]*\)".*/\1/p' "$f")
            alert "transfer '${ds}' (${lb:-bez etykiety}) na ${HOST}: bez pulsu od $(( age / 60 )) min"                   "Rekord transferu '${ds}' wciaz mowi 'running', ale nie odswiezyl sie od $(( age / 60 )) minut (odswieza co 2 s). Transfer najpewniej wisi albo zostal ubity tak, ze kod wyjscia zadania tego nie zglosi. Sprawdz: zfs-backup.sh progress na ${HOST}."
        fi
    done
fi
