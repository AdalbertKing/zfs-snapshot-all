#!/bin/bash
# growth-guard.sh -- STRAŻNIK PODEJRZANEGO PRZYROSTU (U50, właściciel 2026-10-21; ustalenia
# 2026-10-15: "ransomware szyfruje, my widzimy po kaskadowym przyroście", "ostrożnie").
#
# TYLKO ALARM: nic nie kasuje, nic nie wstrzymuje. Dla każdego naszego datasetu ocenia KAŻDY
# przyrost (para kolejnych migawek, wszystkie rodziny razem), którego jeszcze nie ocenił --
# w godzinę mogą powstać dwie migawki (godzinowa i dobowa), na kolektor przychodzą paczką --
# względem normy tego datasetu sprzed tej pary:
#   L = `zfs send -nP -i @a ds@b`  (rozmiar logiczny przyrostu, z metadanych),
#   C = `zfs send -nPc -i @a ds@b` (te same bloki tak, jak leżą na dysku -- skompresowane);
#   L/C = kompresowalność samego przyrostu (zmierzone na pve10: tekst 1,22, dane losowe 1,00).
# ALARM, gdy jednocześnie: tempo L/czas >= factor x mediana tempa z ostatnich `days` dni
# (co najmniej 3 przyrosty historii -- inaczej brak normy); L >= min_mib; L/C <= max_ratio_pct/100.
# Konwersja baz (duży, ale kompresowalny przyrost) nie alarmuje; szyfrowanie plików -- tak.
#
# „Nasze” datasety: lokalne linie delsnaps.sh w blokach zfs-backup-managed crontabów hosta
# (z -R także dzieci) -- jak w capacity-guard.sh. Na źródle i na kolektorze. Pomijane z
# powodem w --plan: compression=off (każdy przyrost wygląda na niekompresowalny), za mało
# historii. Dysk VM szyfrowany w gościu ma zawsze ~1,00 -- tam zostaje sam skok przyrostu.
# Ocenione pary w $STATE/seen (jeden alarm na parę); pierwszy bieg na datasecie tylko
# zapamiętuje historię i ocenia najnowszą parę. Oszacowania zapamiętane po GUID-ach pary.
# Każdy błąd odczytu (crontaby, zfs list, zfs send -nP, zła liczba) = kod 1 i alert
# "strażnik nie działa" -- nigdy ciche "w porządku".
#
# Ustawienia [growth] w settings.ini (F10), kolejność env > settings.ini > zfs-alert.conf >
# domyślne (alert-env.sh): alert off|on (ZFS_GROWTH_ALERT, domyślnie off), factor 5
# (2-100), min_mib 1024 (1-10485760), max_ratio_pct 110 (100-200), days 7 (2-60). Zła
# wartość = nic, kod 1, alert z nazwą.
# Użycie: growth-guard.sh [--plan]  -- --plan: wynik dla każdego datasetu, bez alertów
# (działa także przy alert = off).
set -u
PLAN=0
case "${1:-}" in --plan) PLAN=1 ;; "") ;; *) echo "użycie: growth-guard.sh [--plan]" >&2; exit 2 ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -r "$HERE/alert-env.sh" ] && . "$HERE/alert-env.sh"
ALERT="${ZFS_GROWTH_ALERT:-off}"
FACTOR="${ZFS_GROWTH_FACTOR:-5}"
MINMIB="${ZFS_GROWTH_MIN_MIB:-1024}"
MAXR="${ZFS_GROWTH_MAX_RATIO_PCT:-110}"
DAYS="${ZFS_GROWTH_DAYS:-7}"
NOTIFY="${ZFS_NOTIFY_SCRIPT:-/root/scripts/notify-fail.sh}"
CRONDIR="${ZFS_GUARD_CRONTABS:-/var/spool/cron/crontabs}"
STATE="${ZFS_GROWTH_STATE:-/var/lib/zfs-snapshot-all/growth-guard}"
HOST="$(hostname -s 2>/dev/null || hostname)"

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') growth-guard: $*"; }
alert() {   # <temat> <treść>
    [ "$PLAN" -eq 1 ] && return 0
    if [ -x "$NOTIFY" ]; then "$NOTIFY" "$1" "$2" 2>/dev/null && return 0; fi
    command -v mail >/dev/null 2>&1 && printf '%s\n' "$2" | mail -s "[ZFS GROWTH] $1" "${ZFS_ALERT_EMAIL:-root}" 2>/dev/null
    return 0
}
in_range() {   # <wartość> <min> <max>
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 9 ] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

case "$ALERT" in on|off) ;; *)
    say "alert = '$ALERT' -- dozwolone on albo off; nic nie robię"
    alert "$HOST: strażnik przyrostu -- złe ustawienie alert" "alert = '$ALERT' (ZFS_GROWTH_ALERT / [growth] alert). Dozwolone: on, off."
    exit 1 ;;
esac
if [ "$ALERT" != on ] && [ "$PLAN" -eq 0 ]; then exit 0; fi
bad=""
in_range "$FACTOR" 2 100        || bad="$bad factor='$FACTOR' (2-100)"
in_range "$MINMIB" 1 10485760   || bad="$bad min_mib='$MINMIB' (1-10485760)"
in_range "$MAXR" 100 200        || bad="$bad max_ratio_pct='$MAXR' (100-200)"
in_range "$DAYS" 2 60           || bad="$bad days='$DAYS' (2-60)"
if [ -n "$bad" ]; then
    say "złe ustawienia:$bad -- nic nie robię"
    alert "$HOST: strażnik przyrostu -- złe ustawienia" "Strażnik przyrostu nie sprawdził nic. Złe ustawienia (ZFS_GROWTH_* / [growth] w settings.ini / zfs-alert.conf):$bad"
    exit 1
fi

# Start jak w capacity-guard.sh po REV-20261021-157: pliku blokady nie da się otworzyć albo
# flock zawodzi = strażnik nie działa (kod 1, alert); blokadę trzyma inny bieg = pominięcie
# (kod 0, bez alertu; --plan liczy dalej); nieudane mktemp = kod 1, alert.
LOCKF="${ZFS_GROWTH_LOCK:-/run/lock/zfs-growth-guard.lock}"
start_fail() {   # <powód>
    say "$1 -- strażnik nie startuje"
    alert "$HOST: strażnik przyrostu NIE działa" "Strażnik przyrostu nie wystartował: $1. Żaden dataset nie jest sprawdzany."
    exit 1
}
{ exec 9>"$LOCKF"; } 2>/dev/null || start_fail "nie da się otworzyć pliku blokady $LOCKF"
flock -n -E 75 9 2>/dev/null; lrc=$?
case "$lrc" in
    0) ;;
    75) if [ "$PLAN" -eq 0 ]; then say "inny bieg strażnika trzyma blokadę -- pomijam"; exit 0; fi
        echo "(inny bieg strażnika trwa -- plan liczony bez blokady)" ;;
    *) start_fail "flock $LOCKF zakończył się błędem ($lrc)" ;;
esac
WORK="$(mktemp -d 2>/dev/null)" || start_fail "nie da się utworzyć katalogu tymczasowego (TMPDIR=${TMPDIR:-/tmp})"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STATE" 2>/dev/null
touch "$STATE/cache" "$STATE/seen" 2>/dev/null || { [ "$PLAN" -eq 1 ] || { say "nie da się pisać do $STATE"; exit 1; }; }

errs=""
err() { errs="$errs
$*"; say "BŁĄD: $*"; }

# ---- datasety z lokalnych linii retencji (zarządzane bloki) -> "ds<TAB>rec" ----------
roots() {
    [ -d "$CRONDIR" ] && [ -r "$CRONDIR" ] && [ -x "$CRONDIR" ] || { echo "nie da się czytać $CRONDIR" >&2; return 1; }
    local f
    for f in "$CRONDIR"/*; do
        [ -e "$f" ] || continue
        [ -r "$f" ] || { echo "nie da się czytać $f" >&2; return 1; }
        awk '/^# BEGIN zfs-backup-managed/ { on = 1; next } /^# END zfs-backup-managed/ { on = 0; next } on' "$f" || return 1
    done | awk '
        function tok(s,    i, c, t, n) {
            n = 0; i = 1
            while (i <= length(s)) {
                c = substr(s, i, 1)
                if (c == " " || c == "\t") { i++; continue }
                if (c == "\"") { t = ""; i++; while (i <= length(s) && substr(s, i, 1) != "\"") { t = t substr(s, i, 1); i++ }
                                 if (i > length(s)) return -1; i++; T[++n] = t; continue }
                t = ""; while (i <= length(s) && substr(s, i, 1) != " " && substr(s, i, 1) != "\t") { t = t substr(s, i, 1); i++ }
                if (t ~ /^(2>|>|;|\||&)/) break
                T[++n] = t
            }
            return n
        }
        (p = index($0, "/delsnaps.sh ")) > 0 {
            n = tok(substr($0, p + 13)); if (n < 0) next
            rec = 0; skip = 0; i = 1
            while (i <= n && T[i] ~ /^-/) {
                o = T[i]
                if (o == "-R" || o == "--recursive") rec = 1
                else if (o == "-B" || o == "-n") skip = 1
                else if (o ~ /^-[pkcKOPL]$/) i++
                i++
            }
            if (skip || i > n) next
            m = split(T[i], a, ",")
            for (k = 1; k <= m; k++) if (a[k] != "" && a[k] !~ /:/) print a[k] "\t" rec
        }' | sort -u
}
if ! roots > "$WORK/roots" 2> "$WORK/roots.err"; then
    err "odczyt crontabów: $(head -1 "$WORK/roots.err")"
fi

# ---- rozwinięcie do datasetów z ich kompresją ----------------------------------------
: > "$WORK/ds"
while IFS=$'\t' read -r r rec; do
    [ -n "$r" ] || continue
    if [ "$rec" = 1 ]; then out="$(zfs list -H -o name,compression -t filesystem,volume -r "$r" 2>"$WORK/e")"
    else out="$(zfs list -H -o name,compression -t filesystem,volume "$r" 2>"$WORK/e")"; fi
    if [ $? -ne 0 ]; then err "zfs list $r: $(head -1 "$WORK/e")"; continue; fi
    printf '%s\n' "$out" >> "$WORK/ds"
done < "$WORK/roots"
sort -u "$WORK/ds" -o "$WORK/ds"

size_of() {   # <-c albo ""> <a> <ds@b> -> bajty albo kod 1
    local o v
    o="$(zfs send -nP $1 -i "$2" "$3" 2>/dev/null)" || return 1
    v="$(printf '%s\n' "$o" | awk '$1 == "size" { print $2; exit }')"
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s' "$v"
}

alarms=""; nds=0
win=$((DAYS * 86400))
while IFS=$'\t' read -r ds comp; do
    [ -n "$ds" ] || continue
    nds=$((nds + 1))
    if [ "$comp" = off ]; then [ "$PLAN" -eq 1 ] && echo "$ds: pominięty -- compression=off (każdy przyrost wyglądałby na niekompresowalny)"; continue; fi
    if ! zfs list -H -p -t snapshot -o name,guid,creation -s creation -d 1 "$ds" > "$WORK/s" 2>"$WORK/e"; then
        err "zfs list migawek $ds: $(head -1 "$WORK/e")"; continue
    fi
    if awk -F'\t' 'NF != 3 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = 1 } END { exit !bad }' "$WORK/s"; then
        err "zły wiersz migawki w $ds"; continue
    fi
    newest="$(tail -1 "$WORK/s" | cut -f3)"
    [ -n "$newest" ] || { [ "$PLAN" -eq 1 ] && echo "$ds: brak migawek"; continue; }
    awk -F'\t' -v lim=$((newest - win)) '$3 + 0 >= lim' "$WORK/s" > "$WORK/w"
    np=$(( $(grep -c . "$WORK/w") - 1 ))
    if [ "$np" -lt 4 ]; then [ "$PLAN" -eq 1 ] && echo "$ds: brak normy -- $np przyrost(y) w ${DAYS} dniach, potrzeba 4 (3 historii + najnowszy)"; continue; fi
    # Wszystkie pary kolejnych migawek w oknie (wszystkie rodziny razem: godzinowe i dobowe
    # dają pary o różnych odstępach -- stąd tempo, nie sam rozmiar). Plik: koniec, guid
    # końca, L, C, tempo.
    : > "$WORK/p"; failed=0; prev=""
    while IFS=$'\t' read -r n g c; do
        if [ -n "$prev" ]; then
            IFS=$'\t' read -r pn pg pc <<< "$prev"
            key="$pg-$g"
            hit="$(awk -v k="$key" '$1 == k { print $2 "\t" $3; exit }' "$STATE/cache" 2>/dev/null)"
            if [ -n "$hit" ]; then L="${hit%%$'\t'*}"; C="${hit##*$'\t'}"
            else
                L="$(size_of "" "$pn" "$n")" || { err "zfs send -nP -i $pn $n nie podał rozmiaru"; failed=1; break; }
                C="$(size_of -c "$pn" "$n")" || { err "zfs send -nPc -i $pn $n nie podał rozmiaru"; failed=1; break; }
                [ "$PLAN" -eq 1 ] || printf '%s\t%s\t%s\n' "$key" "$L" "$C" >> "$STATE/cache"
            fi
            dt=$((c - pc)); [ "$dt" -ge 1 ] || dt=1
            printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$g" "$L" "$C" "$((L / dt))" >> "$WORK/p"
        fi
        prev="$n	$g	$c"
    done < "$WORK/w"
    [ "$failed" -eq 0 ] || continue
    # KAŻDA para, której strażnik jeszcze nie ocenił (nie tylko najnowsza): w godzinę mogą
    # powstać dwie migawki (godzinowa i dobowa), a na kolektor przychodzą paczką -- skok w
    # parze, która przestała być najnowsza, przepadłby. Pierwszy bieg na datasecie tylko
    # zapamiętuje historię (bez alarmów za skoki sprzed włączenia), ocenia najnowszą.
    init=1; grep -qxF "init	$ds" "$STATE/seen" 2>/dev/null || init=0
    npairs=$(grep -c . "$WORK/p")
    i=0; shown=0
    while IFS=$'\t' read -r bn bg L C rate; do
        i=$((i + 1))
        [ "$i" -ge 4 ] || continue                                   # potrzeba 3 par historii
        if [ "$init" -eq 0 ] && [ "$i" -lt "$npairs" ]; then
            [ "$PLAN" -eq 1 ] || printf '%s\n' "$bg" >> "$STATE/seen"; continue
        fi
        grep -qxF "$bg" "$STATE/seen" 2>/dev/null && continue
        med="$(head -n $((i - 1)) "$WORK/p" | cut -f5 | sort -n | awk '{ v[NR] = $1 } END { if (NR % 2) print v[(NR + 1) / 2]; else print int((v[NR / 2] + v[NR / 2 + 1]) / 2) }')"
        if [ "$C" -gt 0 ]; then rpct=$((L * 100 / C)); else rpct=999; fi
        mib=$((L / 1048576))
        ratio="$(awk -v p="$rpct" 'BEGIN { printf "%.2f", p / 100 }')"
        if [ "$med" -gt 0 ]; then times="$(awk -v r="$rate" -v m="$med" 'BEGIN { printf "%.1f", r / m }')"; else times="?"; fi
        hot=0
        if [ "$L" -ge $((MINMIB * 1048576)) ] && [ "$rpct" -le "$MAXR" ] && { [ "$med" -eq 0 ] && [ "$rate" -gt 0 ] || [ "$rate" -ge $((FACTOR * med)) ]; }; then hot=1; fi
        line="$ds: przyrost ${mib} MiB (do $bn), tempo ${times}x normy, kompresja przyrostu ${ratio}"
        shown=1
        if [ "$hot" -eq 1 ]; then
            if [ "$PLAN" -eq 1 ]; then echo "$line -- ALARM"; else alarms="$alarms
  $line"; fi
        else
            [ "$PLAN" -eq 1 ] && echo "$line -- w porządku"
        fi
        [ "$PLAN" -eq 1 ] || printf '%s\n' "$bg" >> "$STATE/seen"
    done < "$WORK/p"
    [ "$PLAN" -eq 1 ] || [ "$init" -eq 1 ] || printf 'init\t%s\n' "$ds" >> "$STATE/seen"
    [ "$PLAN" -eq 1 ] && [ "$shown" -eq 0 ] && echo "$ds: brak nowych przyrostów od ostatniego sprawdzenia"
done < "$WORK/ds"

[ "$PLAN" -eq 0 ] && tail -n 5000 "$STATE/cache" > "$WORK/c" 2>/dev/null && cat "$WORK/c" > "$STATE/cache"
[ "$PLAN" -eq 0 ] && { grep "^init" "$STATE/seen"; grep -v "^init" "$STATE/seen" | tail -n 20000; } > "$WORK/sn" 2>/dev/null && cat "$WORK/sn" > "$STATE/seen"
rc=0
if [ -n "$alarms" ]; then
    rc=1
    say "PODEJRZANY PRZYROST:$alarms"
    alert "$HOST: PODEJRZANY PRZYROST danych (możliwe szyfrowanie)" "Najnowszy przyrost jest wielokrotnie większy niż zwykle i prawie się nie kompresuje -- tak wygląda szyfrowanie plików (ransomware), ale też np. wgranie dużej ilości już skompresowanych danych.$alarms
Strażnik niczego nie zatrzymał (tylko alarm). Sprawdź, co się dzieje na tym datasecie, zanim retencja usunie starsze, czyste migawki."
fi
if [ -n "$errs" ]; then
    rc=1
    alert "$HOST: strażnik przyrostu NIE działa w całości" "Nie dało się sprawdzić części datasetów -- dla nich nie ma ochrony:$errs"
fi
[ "$PLAN" -eq 1 ] && [ "$nds" -eq 0 ] && [ -z "$errs" ] && echo "Brak naszych datasetów (lokalnych linii retencji) na tym hoście."
exit "$rc"
