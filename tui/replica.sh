#!/bin/bash
# replica.sh [NAZWA] -- replika na nośnik w oknach whiptail (F6 Nośniki: Ins = nowa,
# Enter + 'e' = zmiana).
#
# Okno NIE ma własnej logiki: pyta o to, o co pyta `zfs-backup.sh add-replica`
# (nazwa, źródła, nośnik, rodzaj, harmonogram), pokazuje PLAN tego czasownika (bez
# --install) i po "WYKONAJ" uruchamia go z --install --yes. add-replica z istniejącą
# nazwą nadpisuje jej sekcję -- to jest zmiana repliki. Czego czasownik odmawia (zły
# dataset, nośnik zajęty przez inną replikę), odmawia tu tak samo, jego słowami.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "replica: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
EDIT=0; [ -n "$NAME" ] && EDIT=1
WT_BACKTITLE="$([ "$EDIT" -eq 1 ] && echo "Zmiana repliki $NAME" || echo "Nowa replika") -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Replika" "Czytam repliki, datasety i nośniki..."
"$ZB" list-replicas --json >"$TMPD/rep.json" 2>"$TMPD/rep.err" || echo '{"replicas":[]}' >"$TMPD/rep.json"
# rep.tsv: nazwa <TAB> źródła(,) <TAB> dst <TAB> harmonogram <TAB> media <TAB> recursive <TAB> próg ostrzeżenia
"$PY" - "$TMPD/rep.json" >"$TMPD/rep.tsv" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("replicas", []):
    print("\t".join([r.get("name") or "-", ",".join(r.get("sources") or [r.get("source") or ""]) or "-",
                     r.get("dst") or "-", r.get("schedule") or "-", r.get("media") or "-", r.get("recursive") or "-",
                     r.get("monitor_warn") or "-"]))
PYEOF
SRCS=""; DST=""; SCHED="30 2 * * *"; MEDIA=removable; REC=yes; TRIG=no; MONDAYS=""
RULES="${ZFS_REPLICA_RULES:-/etc/udev/rules.d/90-zfs-replica.rules}"
if [ "$EDIT" -eq 1 ]; then
    if ! IFS=$'\t' read -r _n SRCS DST SCHED MEDIA REC CURWARN < <(awk -F'\t' -v n="$NAME" '$1==n' "$TMPD/rep.tsv"); then
        wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME].\n(list-replicas: $(tail -1 "$TMPD/rep.err" 2>/dev/null))" 10 "$W"
        exit 1
    fi
    [ "$MEDIA" = - ] && MEDIA=fixed
    case "$REC" in yes|1|true) REC=yes ;; *) REC=no ;; esac
fi
# Pule: zaimportowane i te w slocie (zpool import). Nośnikiem nie może być pula źródła.
zpool list -H -o name 2>/dev/null >"$TMPD/pools.here"
zpool import 2>/dev/null | awk '$1=="pool:"{print $2}' >"$TMPD/pools.slot"
zfs list -H -o name -t filesystem,volume 2>/dev/null >"$TMPD/ds.all"

step=1
while :; do
    geom
    case "$step" in
    1)  # nazwa
        if [ "$EDIT" -eq 1 ]; then step=2; continue; fi
        wt --title "Nowa replika -- 1/5 nazwa" --ok-button "Dalej" --cancel-button "Anuluj" \
           --inputbox "Nazwa repliki (litery, cyfry, . _ -). Nazywa nośnik i stan jego bramy,\nnp. usb1 albo sejf-a." 10 "$W" "$NAME" \
           || { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }
        n="${WT_OUT// /}"
        case "$n" in ''|*[!A-Za-z0-9._-]*) wt --title "Zła nazwa" --msgbox "'$WT_OUT' -- tylko litery, cyfry, kropka, minus, podkreślenie." 8 "$W"; continue ;; esac
        if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/rep.tsv"; then
            wt --title "Nazwa zajęta" --msgbox "Replika '$n' już jest. Zmienia się ją z F6: Enter na niej, potem 'e'." 8 "$W"; continue
        fi
        NAME="$n"; step=2 ;;
    2)  # źródła
        items=()
        while IFS= read -r d; do
            [ -n "$d" ] || continue
            on=OFF; case ",$SRCS," in *",$d,"*) on=ON ;; esac
            items+=("$d" "$(clip_label "$d" $((W - 14)))" "$on")
        done <"$TMPD/ds.all"
        wt --title "Replika $NAME -- 2/5 co kopiować" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Datasety TEGO hosta do skopiowania na nośnik (spacja = zaznacz).\nRazem z dziećmi: $REC. Jeden nośnik może trzymać kilka źródeł." \
           "$H" "$W" "$(lhfit $((${#items[@]} / 3)) 3)" "${items[@]}" || { [ "$EDIT" -eq 1 ] && { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }; step=1; continue; }
        s=$(printf '%s\n' "$WT_OUT" | grep -v '^$' | paste -sd, -)
        [ -n "$s" ] || { wt --title "Nic nie zaznaczono" --msgbox "Zaznacz co najmniej jeden dataset." 8 "$W"; continue; }
        SRCS="$s"; step=3 ;;
    3)  # nośnik
        # Czytane przy KAZDYM wejsciu (uwaga 14, 2026-10-08): dysk podpiety w trakcie kreatora
        # nie pojawial sie po "Wstecz", bo lista byla zrobiona raz, na starcie.
        zpool list -H -o name 2>/dev/null >"$TMPD/pools.here"
        zpool import 2>/dev/null | awk '$1=="pool:"{print $2}' >"$TMPD/pools.slot"
        items=()
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case ",$SRCS," in *",$p,"*|*",$p/"*) continue ;; esac   # pula źródła nie jest nośnikiem
            items+=("$p" "$p  (zaimportowana)")
        done <"$TMPD/pools.here"
        while IFS= read -r p; do [ -n "$p" ] && items+=("$p" "$p  (w slocie, niezaimportowana)"); done <"$TMPD/pools.slot"
        items+=(__other__ "Wpisz nazwę puli…  (nośnik teraz odłączony)")
        cur="${DST%%/*}"
        wt --title "Replika $NAME -- 3/5 nośnik" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "${cur:-__other__}" \
           --menu "Pula na nośniku. Kopia ląduje pod  <pula>/<baza>/<dataset źródła>." "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || { step=2; continue; }
        pool="$WT_OUT"
        if [ "$pool" = __other__ ]; then
            wt --title "Replika $NAME -- nośnik" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Nazwa puli na nośniku (nośnik może być teraz w sejfie):" 9 "$W" "$cur" || continue
            pool="${WT_OUT// /}"; [ -n "$pool" ] || continue
        fi
        def="$DST"; [ "${DST%%/*}" = "$pool" ] || def="$pool/replica"
        wt --title "Replika $NAME -- baza na nośniku" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Dataset bazowy na nośniku. To on mówi bramie, że w slocie jest WŁAŚCIWY dysk." 9 "$W" "$def" || continue
        d="${WT_OUT// /}"
        case "$d" in "$pool"/?*) ;; *) wt --title "Zła baza" --msgbox "'$d' musi leżeć na puli '$pool' (np. $pool/replica)." 8 "$W"; continue ;; esac
        if grep -qxF "$pool" "$TMPD/pools.here" && ! zfs list -H -o name "$d" >/dev/null 2>&1; then
            wt --title "Brak $d" --yes-button "Utwórz" --no-button "Wstecz" \
               --yesno "Pula '$pool' jest zaimportowana, ale nie ma na niej '$d'.\nUtworzyć go teraz (zfs create -p $d)? Tylko na dysku przeznaczonym na replikę." 10 "$W" || continue
            zfs create -p "$d" 2>"$TMPD/zc.err" || { wt --title "zfs create nie wyszedł" --msgbox "$(tail -3 "$TMPD/zc.err")" 10 "$W"; continue; }
        fi
        DST="$d"; step=4 ;;
    4)  # rodzaj nośnika
        wt --title "Replika $NAME -- 4/5 rodzaj nośnika" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$MEDIA" \
           --menu "Wymienny: każdy bieg importuje pulę i eksportuje ją po kopii (dysk można wyjąć).\nStały: pula jest zawsze w maszynie, bez importu/eksportu." 12 "$W" 2 \
           removable "wymienny (USB, dysk do sejfu)" fixed "stały (inna pula w tej maszynie)" || { step=3; continue; }
        MEDIA="$WT_OUT"; step=5 ;;
    5)  # harmonogram
        items=("30 2 * * *" "raz na dobę o 02:30 (domyślnie: po szczeblu dobowym)" "30 3 * * 0" "raz w tygodniu, niedziela 03:30")
        # Tylko wymienny: stały dysk nigdy nie jest "wkładany".
        [ "$MEDIA" = removable ] && items+=(on-insert "tylko po włożeniu dysku (bez godziny; reguła udev)")
        items+=(__other__ "inny wpis crona")
        def="$SCHED"; case "$SCHED" in "30 2 * * *"|"30 3 * * 0"|on-insert) ;; *) def=__other__ ;; esac
        [ "$MEDIA" = fixed ] && [ "$SCHED" = on-insert ] && def="30 2 * * *"
        wt --title "Replika $NAME -- 5/5 kiedy" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "Każdy bieg otwiera nośnik, więc rzadziej = bezpieczniej. Nośnika, którego nie ma,\nbieg nie rusza (cicho). Obecny: $SCHED" "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || { step=4; continue; }
        if [ "$WT_OUT" = __other__ ]; then
            wt --title "Replika $NAME -- harmonogram" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Pięć pól crona (minuta godzina dzień miesiąc dzień-tygodnia):" 9 "$W" "$SCHED" || continue
            SCHED="$(printf '%s' "$WT_OUT" | tr -s ' ')"
        else
            SCHED="$WT_OUT"
        fi
        # OSTRZEŻENIE (2026-10-08): przy harmonogramie progi idą z niego same
        # (dobowo 2/4 dni, tygodniowo 9/14, miesięcznie 35/45). "Po włożeniu" nie ma
        # rytmu, więc tu pytamy: po ilu dniach bez kopii ostrzec (puste = wcale).
        MONDAYS=""
        _defdays=""; case "${CURWARN:-}" in *d) _defdays="${CURWARN%d}" ;; esac
        if [ "$SCHED" = on-insert ]; then
            wt --title "Replika $NAME -- ostrzeżenie" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Po ilu dniach bez kopii na tym nośniku ostrzec (mail z raportu dziennego)?\nAlarm przyjdzie po półtora raza tylu dniach. Puste = bez ostrzeżenia." 10 "$W" "$_defdays" || continue
            MONDAYS="${WT_OUT// /}"
            case "$MONDAYS" in ''|*[!0-9]*) [ -n "$MONDAYS" ] && { wt --title "To nie liczba" --msgbox "Podaj liczbę dni albo zostaw puste." 8 "$W"; continue; } ;; esac
        fi
        # PO WŁOŻENIU = reguła udev (install-media-trigger): jedna na host, uruchamia
        # run-replicas przy każdym dysku z etykietą ZFS. To trwała zmiana tego, jak
        # host reaguje na sprzęt, więc o nią pytamy osobno i tylko gdy jej nie ma.
        TRIG=no
        if [ "$MEDIA" = removable ] && ! grep -qs 'Managed by zfs-backup.sh install-media-trigger' "$RULES"; then
            if [ "$SCHED" = on-insert ]; then
                wt --title "Replika $NAME -- reguła udev" --yes-button "Załóż" --no-button "Wstecz" \
                   --yesno "Replika 'po włożeniu' rusza tylko z reguły udev, a tej reguły na hoście nie ma.\nZałożyć ją (install-media-trigger)? Działa dla wszystkich replik tego hosta:\nkażdy włożony dysk z ZFS uruchamia run-replicas; nie ten dysk = cichy pominięty." 11 "$W" || continue
                TRIG=yes
            else
                wt --title "Replika $NAME -- także po włożeniu?" --yes-button "Tak" --no-button "Nie" --defaultno \
                   --yesno "Oprócz harmonogramu można uruchamiać repliki także zaraz po włożeniu dysku\n(reguła udev, install-media-trigger; jedna na host, dla wszystkich replik).\nZałożyć ją?" 10 "$W" && TRIG=yes
            fi
        fi
        step=6 ;;
    6)  # plan
        ARGV=("$ZB" add-replica "$NAME" "--source=$SRCS" "--dst=$DST" "--schedule=$SCHED")
        [ "$MEDIA" = fixed ] && ARGV+=(--fixed) || ARGV+=(--removable)
        [ "$REC" = yes ] && ARGV+=(--recursive=yes) || ARGV+=(--recursive=no)
        [ -n "$MONDAYS" ] && ARGV+=("--monitor-warn=${MONDAYS}d" "--monitor-crit=$(( (MONDAYS * 3 + 1) / 2 ))d")
        info "Replika $NAME" "Liczę plan..."
        if ! "${ARGV[@]}" --plan >"$TMPD/plan.txt" 2>&1; then
            grep -E '^FATAL' "$TMPD/plan.txt" | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)) >"$TMPD/why.txt"
            [ -s "$TMPD/why.txt" ] || tail -5 "$TMPD/plan.txt" >"$TMPD/why.txt"
            wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
            step=2; continue
        fi
        {
            echo "PLAN -- nic jeszcze nie zostało zmienione:"
            echo
            echo "Replika:    $NAME$([ "$EDIT" -eq 1 ] && echo '  (zmiana istniejącej)')"
            echo "Źródła:     $SRCS  (z dziećmi: $REC)"
            echo "Nośnik:     $DST  ($([ "$MEDIA" = fixed ] && echo stały || echo wymienny))"
            echo "Kiedy:      $([ "$SCHED" = on-insert ] && echo "po włożeniu dysku (bez godziny)" || echo "$SCHED")"
            if [ -n "$MONDAYS" ]; then echo "Ostrzeżenie: po $MONDAYS dniach bez kopii, alarm po $(( (MONDAYS * 3 + 1) / 2 ))"
            elif [ "$SCHED" = on-insert ]; then echo "Ostrzeżenie: brak (replika po włożeniu bez progu)"
            else echo "Ostrzeżenie: z harmonogramu (dobowo 2/4 dni, tygodniowo 9/14, miesięcznie 35/45)"; fi
            if grep -qs 'Managed by zfs-backup.sh install-media-trigger' "$RULES"; then
                echo "Po włożeniu: reguła udev jest ($RULES)"
            elif [ "$TRIG" = yes ]; then
                echo "Po włożeniu: reguła udev ZOSTANIE ZAŁOŻONA (install-media-trigger --install)"
            fi
            grep -E '^(!!!|WARNING|>>> )' "$TMPD/plan.txt" | grep -iv 'plan' | sed 's/^/  /' | head -4
            echo
            echo "Zadanie w cronie:"
            sed -n '/co sie zmieni w crontabie/,$p' "$TMPD/plan.txt" | grep -E "^\s+\+\S" | grep -F "replica" \
                | sed -E 's/^\s+\+//' | awk '{w=($1=="#on-insert")?"po włożeniu":$1" "$2" "$3" "$4" "$5; m=match($0,/zfs-job\.sh "[^"]*"/); l=m?substr($0,RSTART+12,RLENGTH-13):"?"; print "  + " w "   " l}' | head -6
            if [ "$EDIT" -eq 1 ]; then
                echo
                echo "Źródło usunięte z listy zostawia swoją kopię na nośniku (purge-replica-copy ją usuwa)."
            fi
            echo
            echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--install --yes"
        } >"$TMPD/plan2.txt"
        yesno_text "$TMPD/plan2.txt" "Replika $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || { step=2; continue; }
        clear 2>/dev/null
        echo "\$ $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--install --yes"; echo
        "${ARGV[@]}" --install --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
        if [ "$RC" -eq 0 ] && [ "$TRIG" = yes ]; then
            echo; echo "\$ $(shq "$ZB") install-media-trigger --install"
            "$ZB" install-media-trigger --install 2>&1 | tee -a "$TMPD/run.log"; RC=${PIPESTATUS[0]}
        fi
        if [ -n "${ZFS_TUI_LOG:-}" ]; then
            { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
        fi
        echo
        if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: replika '$NAME' zainstalowana (rc=$RC). Pierwszy bieg: wg harmonogramu albo F7 na F6. Enter = dalej"
        else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- nic nie zainstalowano; powód w linii FATAL powyżej. Enter = dalej"; fi
        [ -t 0 ] && read -r _
        exit "$RC" ;;
    esac
done
