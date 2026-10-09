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
# rep.tsv: nazwa <TAB> źródła(,) <TAB> dst <TAB> harmonogram <TAB> media <TAB> recursive <TAB> próg ostrzeżenia <TAB> prefiks ("-" = pasywna)
"$PY" - "$TMPD/rep.json" >"$TMPD/rep.tsv" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("replicas", []):
    print("\t".join([r.get("name") or "-", ",".join(r.get("sources") or [r.get("source") or ""]) or "-",
                     r.get("dst") or "-", r.get("schedule") or "-", r.get("media") or "-", r.get("recursive") or "-",
                     r.get("monitor_warn") or "-", r.get("prefix") or "-"]))
PYEOF
SRCS=""; DST=""; SCHED="0 22 * * *"; MEDIA=removable; REC=yes; TRIG=no; MONDAYS=""; PASSIVE=""
RULES="${ZFS_REPLICA_RULES:-/etc/udev/rules.d/90-zfs-replica.rules}"
if [ "$EDIT" -eq 1 ]; then
    if ! IFS=$'\t' read -r _n SRCS DST SCHED MEDIA REC CURWARN CURPFX < <(awk -F'\t' -v n="$NAME" '$1==n' "$TMPD/rep.tsv"); then
        wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME].\n(list-replicas: $(tail -1 "$TMPD/rep.err" 2>/dev/null))" 10 "$W"
        exit 1
    fi
    [ "$MEDIA" = - ] && MEDIA=fixed
    case "$REC" in yes|1|true) REC=yes ;; *) REC=no ;; esac
    [ "${CURPFX:-}" = - ] && PASSIVE=yes || PASSIVE=no
fi
RULE_HERE=no; grep -qs 'Managed by zfs-backup.sh install-media-trigger' "$RULES" && RULE_HERE=yes

# Lądowiska relacji na tym kolektorze (managed_datasets z status --json): replika,
# której źródło je obejmuje, ma domyślnie NIE robić własnych migawek (uwaga 20).
"$ZB" status --json 2>/dev/null | "$PY" -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: d = {}
for r in d.get("relations", []):
    if r.get("state") == "removed": continue
    for m in r.get("managed_datasets") or []:
        if m and m != "*": print(m)' >"$TMPD/landings" 2>/dev/null
covers_landing() {   # -> 0, gdy któreś źródło z $SRCS jest lądowiskiem albo je zawiera
    local s l
    for s in ${SRCS//,/ }; do
        while IFS= read -r l; do
            case "$l" in "$s"|"$s"/*) return 0 ;; esac
        done <"$TMPD/landings"
    done
    return 1
}
# Pule: zaimportowane i te w slocie (zpool import). Nośnikiem nie może być pula źródła.
zpool list -H -o name 2>/dev/null >"$TMPD/pools.here"
zpool import 2>/dev/null | awk '$1=="pool:"{print $2}' >"$TMPD/pools.slot"
zfs list -H -o name -t filesystem,volume 2>/dev/null >"$TMPD/ds.all"

# PRZYGOTOWANIE NOŚNIKA (uwaga 15, 2026-10-08): pusty dysk -> pula repliki, przez wsad
# prepare-media (zpool create -m none -o failmode=continue, zfs create POOL/BAZA, export).
# Dwie drogi, jeden czasownik: nowy nośnik (pula i baza do wpisania) albo kolejny dysk
# TEJ repliki (rotacja: ta sama pula i baza, brama rozróżnia dyski po GUID).
# 0 = przygotowano (PREP_DST), 1 = wstecz.
prep_media() {   # <pula> <baza> <stałe: 1 = nie pytaj o nazwy>
    local pool="$1" base="$2" fixed="$3" items=() id sz model serial onit dev
    info "Replika $NAME -- nośnik" "Szukam dysków, których nic nie używa..."
    "$ZB" prepare-media --list >"$TMPD/disks.tsv" 2>"$TMPD/disks.err" || :
    while IFS=$'\t' read -r id sz model serial onit; do
        [ -n "$id" ] || continue
        case "$onit" in -) onit="pusty" ;; zfs:*) onit="UWAGA: ma pulę ${onit#zfs:}" ;; *) onit="ma: $onit" ;; esac
        items+=("$id" "$(clip_label "$sz  $model  $serial  ($onit)" $((W - 12)))")
    done <"$TMPD/disks.tsv"
    if [ "${#items[@]}" -eq 0 ]; then
        wt --title "Brak wolnego dysku" --msgbox "Każdy dysk tego hosta jest w puli albo zamontowany.\nPodłącz dysk na nośnik i wybierz to jeszcze raz.$( [ -s "$TMPD/disks.err" ] && printf '\n\n%s' "$(tail -2 "$TMPD/disks.err")")" 10 "$W"
        return 1
    fi
    geom
    wt --title "Replika $NAME -- który dysk?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --menu "Dyski, których nic nie używa. Wybrany zostanie WYCZYSZCZONY." "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
       "${items[@]}" || return 1
    dev="$WT_OUT"
    if [ "$fixed" != 1 ]; then
        wt --title "Replika $NAME -- nazwa puli" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Nazwa puli na nośniku. Drugi dysk tej samej repliki dostaje tę samą nazwę." 9 "$W" "$pool" || return 1
        pool="${WT_OUT// /}"; [ -n "$pool" ] || return 1
        wt --title "Replika $NAME -- baza na nośniku" --ok-button "Dalej" --cancel-button "Wstecz" \
           --inputbox "Dataset bazowy na nośniku -- po nim brama poznaje właściwy dysk." 9 "$W" "$base" || return 1
        base="${WT_OUT// /}"; [ -n "$base" ] || return 1
    fi
    "$ZB" prepare-media "$pool" "$dev" --base="$base" >"$TMPD/prep.plan" 2>&1
    if ! grep -q '^PLAN' "$TMPD/prep.plan"; then
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(grep -E 'FATAL' "$TMPD/prep.plan" | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    yesno_text "$TMPD/prep.plan" "Replika $NAME -- przygotowanie nośnika" "Przygotuj (KASUJE dysk)" "Wstecz" --defaultno || return 1
    info "Replika $NAME -- nośnik" "Przygotowuję $dev..."
    if ! "$ZB" prepare-media "$pool" "$dev" --base="$base" --yes >"$TMPD/prep.log" 2>&1; then
        wt --title "Przygotowanie nie wyszło" --msgbox "$(tail -4 "$TMPD/prep.log" | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    PREP_DST="$pool/$base"
    return 0
}

step=1
while :; do
    geom
    case "$step" in
    1)  # nazwa
        if [ "$EDIT" -eq 1 ]; then step=2; continue; fi
        wt --title "Nowa replika -- 1/6 nazwa" --ok-button "Dalej" --cancel-button "Anuluj" \
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
        wt --title "Replika $NAME -- 2/6 co kopiować" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
           --checklist "Datasety TEGO hosta do skopiowania na nośnik (spacja = zaznacz).\nRazem z dziećmi: $REC. Jeden nośnik może trzymać kilka źródeł." \
           "$H" "$W" "$(lhfit $((${#items[@]} / 3)) 3)" "${items[@]}" || { [ "$EDIT" -eq 1 ] && { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }; step=1; continue; }
        s=$(printf '%s\n' "$WT_OUT" | grep -v '^$' | paste -sd, -)
        [ -n "$s" ] || { wt --title "Nic nie zaznaczono" --msgbox "Zaznacz co najmniej jeden dataset." 8 "$W"; continue; }
        SRCS="$s"; step=25 ;;
    25) # migawki: własne czy istniejące (uwaga 20, 2026-10-08)
        # Kopie relacji na tym kolektorze dostają migawki od swojego źródła; migawka
        # replica_ postawiona na nich znika przy następnym pobraniu (kopia idzie za
        # źródłem). Dla nich domyślnie: bez własnych migawek.
        def=own; covers_landing && def=passive
        [ "$PASSIVE" = yes ] && def=passive; [ "$PASSIVE" = no ] && def=own
        lead=""; covers_landing && lead="Źródło obejmuje kopie relacji tego kolektora -- dla nich polecane\n'istniejące': migawka replica_ zniknęłaby przy następnym pobraniu relacji.\n\n"
        wt --title "Replika $NAME -- 3/6 migawki" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "${lead}Jakie migawki ma przenosić replika?" "$(fit 9)" "$W" 2 \
           passive "Istniejące -- bez własnych migawek (kopiuje to, co już jest)" \
           own "Własne -- przy każdym biegu migawka z przedrostkiem replica_" || { step=2; continue; }
        [ "$WT_OUT" = passive ] && PASSIVE=yes || PASSIVE=no
        step=3 ;;
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
        # Dwa dyski jednej repliki w slocie mają tę samą nazwę puli: jedna pozycja.
        while IFS= read -r p; do [ -n "$p" ] && items+=("$p" "$p  (w slocie, niezaimportowana)"); done < <(sort -u "$TMPD/pools.slot")
        items+=(__other__ "Wpisz nazwę puli…  (nośnik teraz odłączony)")
        items+=(__prep__ "Przygotuj nowy nośnik…  (pusty dysk -> pula repliki)")
        [ "$EDIT" -eq 1 ] && [ -n "$DST" ] && items+=(__rot__ "Przygotuj kolejny dysk dla tej repliki…  (${DST%%/*}, ta sama baza)")
        cur="${DST%%/*}"
        wt --title "Replika $NAME -- 4/6 nośnik" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "${cur:-__other__}" \
           --menu "Pula na nośniku. Kopia ląduje pod  <pula>/<baza>/<dataset źródła>." "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || { step=25; continue; }
        pool="$WT_OUT"
        if [ "$pool" = __prep__ ]; then
            prep_media "repl" "replica" 0 || continue
            DST="$PREP_DST"; step=4; continue
        fi
        if [ "$pool" = __rot__ ]; then
            # Ta sama pula i baza co replika: dysk do rotacji, sama replika się nie zmienia.
            if prep_media "${DST%%/*}" "${DST#*/}" 1; then
                wt --title "Kolejny dysk gotowy" --msgbox "Drugi dysk repliki '$NAME' jest gotowy ($DST).\nDo slotu wkładaj JEDEN dysk naraz -- dwa z tą samą pulą brama odrzuca." 10 "$W"
            fi
            continue
        fi
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
        wt --title "Replika $NAME -- 5/6 rodzaj nośnika" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$MEDIA" \
           --menu "Wymienny: każdy bieg importuje pulę i eksportuje ją po kopii (dysk można wyjąć).\nStały: pula jest zawsze w maszynie, bez importu/eksportu." 12 "$W" 2 \
           removable "wymienny (USB, dysk do sejfu)" fixed "stały (inna pula w tej maszynie)" || { step=3; continue; }
        MEDIA="$WT_OUT"; step=5 ;;
    5)  # harmonogram -- okno A "Kiedy kopiować?" i okno B "także po włożeniu?"
        # (właściciel 2026-10-08, zastępuje uwagi 16 i 19). Reguła udev nie ma
        # osobnego pytania: gdy jest potrzebna i jej nie ma, plan wymienia ją jako krok.
        items=("0 22 * * *" "codziennie o 22:00" "0 22 * * 5" "co tydzień, piątek 22:00" "0 22 1 * *" "co miesiąc, 1. dnia o 22:00"
               __other__ "własny harmonogram (cron)…")
        # Tylko wymienny: stały dysk nigdy nie jest "wkładany".
        [ "$MEDIA" = removable ] && items+=(on-insert "tylko po włożeniu dysku")
        def="$SCHED"; case "$SCHED" in "0 22 * * *"|"0 22 * * 5"|"0 22 1 * *"|on-insert) ;; *) def=__other__ ;; esac
        [ "$MEDIA" = fixed ] && [ "$SCHED" = on-insert ] && def="0 22 * * *"
        wt --title "Replika $NAME -- 6/6 kiedy kopiować?" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "Każdy bieg otwiera nośnik, więc rzadziej = bezpieczniej. Nośnika, którego nie ma,\nbieg nie rusza (cicho). Obecny: $([ "$SCHED" = on-insert ] && echo 'tylko po włożeniu' || echo "$SCHED")" "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || { step=4; continue; }
        if [ "$WT_OUT" = __other__ ]; then
            wt --title "Replika $NAME -- własny harmonogram" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Pięć pól crona (minuta godzina dzień miesiąc dzień-tygodnia):" 9 "$W" "$([ "$SCHED" = on-insert ] || echo "$SCHED")" || continue
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
        # Okno B: tylko nośnik wymienny z harmonogramem, i tylko gdy reguły jeszcze nie
        # ma -- reguła jest jedna na host i uruchamia przy włożeniu WSZYSTKIE repliki,
        # więc gdy już jest, "nie" niczego by nie zmieniło.
        TRIG=no
        if [ "$MEDIA" = removable ] && [ "$RULE_HERE" = no ]; then
            if [ "$SCHED" = on-insert ]; then
                TRIG=yes
            else
                wt --title "Replika $NAME -- także po włożeniu?" --yes-button "Tak" --no-button "Nie" \
                   --yesno "Uruchamiać kopię także od razu po włożeniu dysku?\n\nTak: włożony dysk repliki -- kopia od razu, potem dalej wg harmonogramu.\nKażdy inny dysk -- nic się nie dzieje." 11 "$W" && TRIG=yes
            fi
        fi
        step=6 ;;
    6)  # plan
        ARGV=("$ZB" add-replica "$NAME" "--source=$SRCS" "--dst=$DST" "--schedule=$SCHED")
        [ "$MEDIA" = fixed ] && ARGV+=(--fixed) || ARGV+=(--removable)
        [ "$REC" = yes ] && ARGV+=(--recursive=yes) || ARGV+=(--recursive=no)
        [ "$PASSIVE" = yes ] && ARGV+=(--passive)
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
            echo "Migawki:    $([ "$PASSIVE" = yes ] && echo "istniejące -- bez własnych" || echo "własne, przedrostek replica_")"
            echo "Nośnik:     $DST  ($([ "$MEDIA" = fixed ] && echo stały || echo wymienny))"
            echo "Kiedy:      $([ "$SCHED" = on-insert ] && echo "tylko po włożeniu dysku" || echo "$SCHED")"
            if [ -n "$MONDAYS" ]; then echo "Ostrzeżenie: po $MONDAYS dniach bez kopii, alarm po $(( (MONDAYS * 3 + 1) / 2 ))"
            elif [ "$SCHED" = on-insert ]; then echo "Ostrzeżenie: brak (replika po włożeniu bez progu)"
            else echo "Ostrzeżenie: z harmonogramu (dobowo 2/4 dni, tygodniowo 9/14, miesięcznie 35/45)"; fi
            if [ "$MEDIA" = removable ] && [ "$RULE_HERE" = yes ]; then
                echo "Po włożeniu: kopia rusza od razu (reguła udev jest na hoście)"
            elif [ "$TRIG" = yes ]; then
                echo "Po włożeniu: kopia rusza od razu -- krok: reguła udev ZOSTANIE ZAŁOŻONA"
                echo "             (install-media-trigger --install; jedna na host, dla wszystkich replik)"
            elif [ "$MEDIA" = removable ]; then
                echo "Po włożeniu: nic -- kopia tylko wg harmonogramu"
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
        if [ "$RC" -eq 0 ]; then
            if [ "$SCHED" = on-insert ]; then _first="po włożeniu dysku albo teraz: F7 na F6"
            elif [ "$MEDIA" = removable ] && { [ "$TRIG" = yes ] || [ "$RULE_HERE" = yes ]; }; then _first="po włożeniu dysku, wg harmonogramu albo teraz: F7 na F6"
            else _first="wg harmonogramu albo teraz: F7 na F6"; fi
            echo "=== GOTOWE: replika '$NAME' zainstalowana (rc=$RC). Pierwsza kopia: $_first. Enter = dalej"
        else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- nic nie zainstalowano; powód w linii FATAL powyżej. Enter = dalej"; fi
        [ -t 0 ] && read -r _
        exit "$RC" ;;
    esac
done
