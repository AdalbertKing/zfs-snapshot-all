# alert-env.sh -- the alert scripts' shared config/env preamble. Sourced, never
# executed, by capacity-guard.sh, notify-fail.sh, notify-warn.sh, alert-digest.sh and (on its
# fallback path) check-pool-capacity.sh, from the directory each of them is
# installed in: root's /root/scripts, a delegated account's $HOME. deploy.sh
# installs it beside them from this file, byte for byte.
#
# Until 2026-09-03 this text was a deploy.sh variable interpolated into three
# generated scripts, because a script generated from a heredoc had nothing to
# source. Now that the scripts are files in the checkout, so is this.
# The ENVIRONMENT wins over the config file. Sourcing the config last looks
# harmless until you notice these are exactly the knobs a test sets: a run with
# ZFS_ALERT_QUEUE pointed at a scratch file silently used the PRODUCTION queue
# instead -- summarised it, mailed it and deleted it. Snapshot the env values
# before the config can overwrite them, then put them back.
_E_MODE="${ZFS_ALERT_MODE:-}"; _E_WMODE="${ZFS_WARN_MODE:-}"
_E_QUEUE="${ZFS_ALERT_QUEUE:-}"; _E_EMAIL="${ZFS_ALERT_EMAIL:-}"
_E_STATE="${ZFS_ALERT_STATE_DIR:-}"
# The two digest knobs obey the same rule. They did not: the file won for them
# while the environment won for the five above, so the SAME config had two
# precedence rules depending on which key you touched -- which is the kind of
# thing that costs an hour when a test run quietly reads production settings.
_E_DAYS="${ZFS_DIGEST_DAYS:-}"; _E_QUIET="${ZFS_DIGEST_QUIET:-}"
CONF="${ZFS_ALERT_CONF:-}"
if [ -z "$CONF" ]; then
    # /etc first: /root is 0700, so a delegated service account (see
    # phase 8) cannot read anything under it. The old in-/root
    # location stays as a fallback so an un-migrated host keeps working.
    for c in /etc/zfs-alert.conf /root/scripts/zfs-alert.conf; do
        [ -r "$c" ] && { CONF="$c"; break; }
    done
fi
# The REAL environment, taken BEFORE the legacy conf is sourced (GitHub #655 P1-C):
# taken after it, a conf value passed for "environment" and _restore_env put it back
# over settings.ini -- a legacy ZFS_GUARD=on beat an F10 guard = off. Order of
# weight: environment > settings.ini > zfs-alert.conf > defaults.
_E_G="${ZFS_GUARD:-}"; _E_GA="${ZFS_GUARD_AT:-}"; _E_GT="${ZFS_GUARD_TARGET:-}"; _E_GK="${ZFS_GUARD_MIN_KEEP:-}"
_E_WA="${ZFS_GROWTH_ALERT:-}"; _E_WF="${ZFS_GROWTH_FACTOR:-}"; _E_WM="${ZFS_GROWTH_MIN_MIB:-}"
_E_WR="${ZFS_GROWTH_MAX_RATIO_PCT:-}"; _E_WD="${ZFS_GROWTH_DAYS:-}"
_E_COOL="${ZFS_ALERT_COOLDOWN:-}"; _E_CAP="${ZFS_CAPACITY_THRESHOLD:-}"
# shellcheck disable=SC1090
[ -n "$CONF" ] && . "$CONF"
# THE HOST SETTINGS FILE (2026-10-19, owner: "nowy plik ustawień z sekcjami", edited
# with F10 in the GUI). Its [alerts] and [capacity] keys win over zfs-alert.conf --
# the GUI writes only this file, so what the admin set there must be what runs --
# and the environment still wins over both (the suites pin values that way).
# Read with awk here, not lib-cron.sh's settings_get: these scripts are installed
# beside the alert queue, away from the checkout.
_ZS_FILE="${SETTINGS_FILE:-/etc/zfs-snapshot-all/settings.ini}"
_zs() {   # <section> <key> -> value or nothing
    [ -r "$_ZS_FILE" ] || return 0
    awk -F= -v s="$1" -v k="$2" '
        BEGIN { cur = "engine" }
        { sub(/#.*/, "") }
        /^[ \t]*\[[A-Za-z0-9_]+\][ \t]*$/ { cur = $0; gsub(/[][ \t]/, "", cur); next }
        { kk = $1; gsub(/^[ \t]+|[ \t]+$/, "", kk)
          if (cur == s && kk == k && NF > 1) { v = $0; sub(/^[^=]*=/, "", v); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit } }' "$_ZS_FILE" 2>/dev/null
}
_v=$(_zs alerts email);        [ -n "$_v" ] && ZFS_ALERT_EMAIL="$_v"
_v=$(_zs alerts errors);       [ -n "$_v" ] && ZFS_ALERT_MODE="$_v"
_v=$(_zs alerts warnings);     [ -n "$_v" ] && ZFS_WARN_MODE="$_v"
_v=$(_zs alerts all_ok_mail);  [ -n "$_v" ] && ZFS_DIGEST_QUIET="$_v"
_v=$(_zs alerts stats_days);   [ -n "$_v" ] && ZFS_DIGEST_DAYS="$_v"
_v=$(_zs capacity threshold);  [ -n "$_v" ] && ZFS_CAPACITY_THRESHOLD="$_v"
# U35 bezpiecznik pojemności (capacity-guard.sh)
_v=$(_zs capacity guard);          [ -n "$_v" ] && ZFS_GUARD="$_v"
_v=$(_zs capacity guard_at);       [ -n "$_v" ] && ZFS_GUARD_AT="$_v"
_v=$(_zs capacity guard_target);   [ -n "$_v" ] && ZFS_GUARD_TARGET="$_v"
_v=$(_zs capacity guard_min_keep); [ -n "$_v" ] && ZFS_GUARD_MIN_KEEP="$_v"
# U50 strażnik podejrzanego przyrostu (growth-guard.sh)
_v=$(_zs growth alert);          [ -n "$_v" ] && ZFS_GROWTH_ALERT="$_v"
_v=$(_zs growth factor);         [ -n "$_v" ] && ZFS_GROWTH_FACTOR="$_v"
_v=$(_zs growth min_mib);        [ -n "$_v" ] && ZFS_GROWTH_MIN_MIB="$_v"
_v=$(_zs growth max_ratio_pct);  [ -n "$_v" ] && ZFS_GROWTH_MAX_RATIO_PCT="$_v"
_v=$(_zs growth days);           [ -n "$_v" ] && ZFS_GROWTH_DAYS="$_v"
_v=$(_zs alerts repeat_after)
case "$_v" in
    *[0-9]h) ZFS_ALERT_COOLDOWN=$(( ${_v%h} * 3600 )) ;;
    *[0-9]m) ZFS_ALERT_COOLDOWN=$(( ${_v%m} * 60 )) ;;
    *[0-9])  ZFS_ALERT_COOLDOWN="$_v" ;;
esac
unset _v
_restore_env() {
    [ -n "$_E_COOL" ]  && ZFS_ALERT_COOLDOWN="$_E_COOL"
    [ -n "$_E_CAP" ]   && ZFS_CAPACITY_THRESHOLD="$_E_CAP"
    [ -n "$_E_G" ]     && ZFS_GUARD="$_E_G"
    [ -n "$_E_GA" ]    && ZFS_GUARD_AT="$_E_GA"
    [ -n "$_E_GT" ]    && ZFS_GUARD_TARGET="$_E_GT"
    [ -n "$_E_GK" ]    && ZFS_GUARD_MIN_KEEP="$_E_GK"
    [ -n "$_E_WA" ]    && ZFS_GROWTH_ALERT="$_E_WA"
    [ -n "$_E_WF" ]    && ZFS_GROWTH_FACTOR="$_E_WF"
    [ -n "$_E_WM" ]    && ZFS_GROWTH_MIN_MIB="$_E_WM"
    [ -n "$_E_WR" ]    && ZFS_GROWTH_MAX_RATIO_PCT="$_E_WR"
    [ -n "$_E_WD" ]    && ZFS_GROWTH_DAYS="$_E_WD"
    [ -n "$_E_MODE" ]  && ZFS_ALERT_MODE="$_E_MODE"
    [ -n "$_E_WMODE" ] && ZFS_WARN_MODE="$_E_WMODE"
    [ -n "$_E_QUEUE" ] && ZFS_ALERT_QUEUE="$_E_QUEUE"
    [ -n "$_E_EMAIL" ] && ZFS_ALERT_EMAIL="$_E_EMAIL"
    [ -n "$_E_STATE" ] && ZFS_ALERT_STATE_DIR="$_E_STATE"
    [ -n "$_E_DAYS" ]  && ZFS_DIGEST_DAYS="$_E_DAYS"
    [ -n "$_E_QUIET" ] && ZFS_DIGEST_QUIET="$_E_QUIET"
    return 0
}
_restore_env

# ---------------------------------------------------------------------------
# U158 (Dabrowska pve0 2026-11-04): a single alert in the admin's words. The subject
# was the job's internal label ("profile__relacja-X__lsrc_yearly stale (...)"), with
# no sentence of what it means, and a monitor counting from the dataset's creation
# could not be told from a real failure. Plain ASCII: these go out through mail -s
# where there is no sendmail, as they always have.
#
# alert_words <label> <detail> -> AW_REL (relation, or the label's own words), AW_WHAT
# (what happened, for the subject), AW_SAY (what it means / what to do, one or two lines).
alert_words() {
    local k="$1" det="$2" note="" scope="" tier="" word="" t f g m age
    case "$k" in *" -- "*) note="${k#* -- }"; k="${k%% -- *}" ;; esac
    case "$k" in *" profile__"*) k="profile__${k#* profile__}" ;; esac
    case "$k" in *" ("*")") scope="${k##* (}"; scope="${scope%)}"; k="${k% (*}" ;; esac
    AW_REL=""
    case "$k" in
        profile__relacja-*__*) AW_REL="${k#profile__relacja-}"; AW_REL="${AW_REL%__*}"; k="${k##*__}" ;;
        profile__*__*) k="${k##*__}" ;;
        # notify_text is "HOST TIER WORD": the host goes when two words remain after it.
        *" "*" "*) k="${k#* }" ;;
    esac
    tier="${k%% *}"; word="${k#* }"
    [ "$word" = "$k" ] && word=""
    t="${tier##*_}"
    case "$t" in
        hourly) f=godzinowa; g=godzinowej; m=godzinowy ;; daily) f=dobowa; g=dobowej; m=dobowy ;;
        weekly) f=tygodniowa; g=tygodniowej; m=tygodniowy ;; monthly) f=miesieczna; g=miesiecznej; m=miesieczny ;;
        yearly|annual) f=roczna; g=rocznej; m=roczny ;; *) f="$t"; g="$t"; m="$t" ;;
    esac
    [ -n "$AW_REL" ] || AW_REL="$scope"
    age=$(printf '%s\n' "$det" | sed -n 's/.*age=\([^ ]*\).*/\1/p' | head -1)
    case "$note" in
        "without quiescing the guest"*)
            AW_WHAT="migawka $f bez zamrozenia goscia"
            AW_SAY="Migawka jest, ale zrobiona bez zamrozenia goscia -- spojna jak po naglym wylaczeniu.
Powod jest w logu biegu (ponizej): np. agent goscia niedostepny albo konto bez dostepu do gosci." ;;
        skipped*)
            AW_WHAT="bieg pominiety, poprzedni jeszcze trwa"
            AW_SAY="Poprzedni bieg tego zadania trzymal blokade; ten nie ruszyl. Jednorazowo to nic; stale -- bieg trwa dluzej niz odstep." ;;
        "guest disks left out"*)
            AW_WHAT="dyski goscia pominiete"
            AW_SAY="Czesc gosci ma tu tylko replike pvesr -- ich dyski pominieto, reszta drzewa poszla. Kopie takich gosci rob tam, gdzie dzialaja." ;;
        *)
            case "$word" in
                snapshot) AW_WHAT="migawka $f nie powiodla sie" ;;
                backup)   AW_WHAT="kopia $f nie powiodla sie" ;;
                prune)    AW_WHAT="czyszczenie (szczebel $m) nie powiodlo sie" ;;
                stale)    AW_WHAT="brak swiezej migawki $g${age:+ (najnowsza sprzed $age)}"
                          case "$det" in *"no snapshot found"*) AW_WHAT="brak jakiejkolwiek migawki $g" ;; esac ;;
                "getting stale") AW_WHAT="migawka $f spozniona${age:+ (najnowsza sprzed $age)}" ;;
                "monitor BROKEN") AW_WHAT="monitor nie odpowiada" ;;
                *) AW_WHAT="${word:-$tier}" ;;
            esac
            case "$word" in
                snapshot|backup|prune)
                    AW_SAY="Ostatni bieg skonczyl sie bledem; to, co juz bylo, zostaje. Ostatnie linie bledu ponizej.
Sprawdz: zfs-backup gui -> F2 (przebiegi)." ;;
                stale|"getting stale")
                    AW_SAY="Najnowsza migawka tego szczebla jest starsza niz prog -- nowe nie powstaja albo nie docieraja.
Sprawdz: zfs-backup gui -> F3 (relacja) i F2 (przebiegi)."
                    case "$det" in *"age measured from dataset creation"*)
                        AW_SAY="$AW_SAY
Tego szczebla nie ma jeszcze ani jednej migawki, a monitor liczy wiek od utworzenia datasetu
(monitor bez startu relacji, relacja sprzed 1.0.6). Jesli szczebel nie mial jeszcze pierwszego
terminu (np. roczna), to nie jest awaria." ;;
                    esac ;;
                "monitor BROKEN")
                    AW_SAY="Monitor nie mogl sprawdzic wieku migawek (dataset, uprawnienia, polaczenie) -- powod ponizej." ;;
                *) AW_SAY="" ;;
            esac ;;
    esac
}

# alert_sendmail -> the sendmail binary, or nothing. ZFS_SENDMAIL overrides ("none" = do not use).
alert_sendmail() {
    local s="${ZFS_SENDMAIL:-}"
    [ -n "$s" ] || s=$(command -v sendmail 2>/dev/null)
    [ -n "$s" ] || { [ -x /usr/sbin/sendmail ] && s=/usr/sbin/sendmail; }
    [ -n "$s" ] && [ "$s" != none ] && printf '%s' "$s"
}

# alert_mail <subject> <to> < body -- with a sender the admin recognises ("zfs-backup <host>")
# when there is a sendmail; plain mail -s otherwise. ASCII subject and body.
alert_mail() {
    local sm h
    sm=$(alert_sendmail)
    h=$(hostname -f 2>/dev/null || hostname)
    if [ -n "$sm" ]; then
        { printf 'From: zfs-backup %s <%s@%s>\nTo: %s\nSubject: %s\nMIME-Version: 1.0\nContent-Type: text/plain; charset=us-ascii\n\n' \
              "${h%%.*}" "$(id -un 2>/dev/null || echo root)" "$h" "$2" "$1"; cat; } | "$sm" -t -oi
    else
        mail -s "$1" "$2"
    fi
}
