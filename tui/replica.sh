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
. "$HERE/tui/basket-lib.sh" || { echo "replica: brak $HERE/tui/basket-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
EDIT=0; [ -n "$NAME" ] && EDIT=1
WT_BACKTITLE="$([ "$EDIT" -eq 1 ] && echo "Zmiana repliki $NAME" || echo "Nowa replika") -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Replika" "Czytam repliki, datasety i nośniki..."
"$ZB" list-replicas --json >"$TMPD/rep.json" 2>"$TMPD/rep.err" || echo '{"replicas":[]}' >"$TMPD/rep.json"
# rep.tsv: nazwa <TAB> źródła(,) <TAB> dst <TAB> harmonogram <TAB> media <TAB> recursive <TAB> próg ostrzeżenia <TAB> prefiks ("-" = pasywna) <TAB> wyjątki (-X, spacjami)
"$PY" - "$TMPD/rep.json" >"$TMPD/rep.tsv" <<'PYEOF'
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("replicas", []):
    print("\t".join([r.get("name") or "-", ",".join(r.get("sources") or [r.get("source") or ""]) or "-",
                     r.get("dst") or "-", r.get("schedule") or "-", r.get("media") or "-", r.get("recursive") or "-",
                     r.get("monitor_warn") or "-", r.get("prefix") or "-", " ".join(r.get("exclude_child") or []) or "-",
                     r.get("media_guids") or "-", r.get("on_insert") or "no"]))
PYEOF
SRCS=""; DST=""; SCHED="0 22 * * *"; MEDIA=removable; REC=yes; TRIG=no; MONDAYS=""; PASSIVE=""
GUIDS=""; ONINS=no; CURGUIDS=""
RULES="${ZFS_REPLICA_RULES:-/etc/udev/rules.d/90-zfs-replica.rules}"
if [ "$EDIT" -eq 1 ]; then
    if ! IFS=$'\t' read -r _n SRCS DST SCHED MEDIA REC CURWARN CURPFX CURX CURGUIDS ONINS < <(awk -F'\t' -v n="$NAME" '$1==n' "$TMPD/rep.tsv"); then
        wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME].\n(list-replicas: $(tail -1 "$TMPD/rep.err" 2>/dev/null))" 10 "$W"
        exit 1
    fi
    [ "$MEDIA" = - ] && MEDIA=fixed
    case "$REC" in yes|1|true) REC=yes ;; *) REC=no ;; esac
    [ "${CURPFX:-}" = - ] && PASSIVE=yes || PASSIVE=no
    [ "${CURGUIDS:-}" = - ] && CURGUIDS=""; GUIDS="$CURGUIDS"
    [ "${ONINS:-}" = yes ] || ONINS=no
fi
# Reguła udev sprzed P5 (run-replicas bez --on-insert) uruchamiała przy włożeniu WSZYSTKIE
# repliki; plan ją wtedy odnawia (install-media-trigger --install), jak brakującą.
RULE_HERE=no; grep -qs 'Managed by zfs-backup.sh install-media-trigger' "$RULES" && RULE_HERE=yes
[ "$RULE_HERE" = yes ] && ! grep -qs 'run-replicas --on-insert' "$RULES" && RULE_HERE=old

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
# Koszyk (basket-lib.sh) w replice: datasety TEGO hosta, zawsze z dziećmi (-R), bez
# pozycji "Sposób". title() -- nagłówek okien koszyka jako krok 2/6 repliki.
HOST="$(hostname -s 2>/dev/null || hostname)"; RECURSION=flat; BASKET_NO_MODE=1
title() { printf 'Replika %s -- 2/6 %s' "${NAME:-}" "$2"; }
basket_from_replica() {   # SRCS + CURX (wzorce -X) -> B_ROOT/B_EXCL; '^x$' to pominięty x, '^x/' jego dzieci
    local r x
    B_ROOT=(); B_EXCL=()
    for r in ${SRCS//,/ }; do
        [ -n "$r" ] && [ "$r" != - ] || continue
        local ex=""
        for x in ${CURX:-}; do
            [ "$x" = - ] && continue
            case "$x" in "^$r/"*'$') x="${x#^}"; ex="$ex${ex:+$'\n'}${x%\$}" ;; esac
        done
        B_ROOT+=("$r"); B_EXCL+=("$ex")
    done
}
basket_xargs() {          # B_EXCL -> XARGS: --exclude-child=^x$ (i ^x/, gdy x ma dzieci) -- jak w relacji
    local i x
    XARGS=()
    for i in "${!B_ROOT[@]}"; do
        while IFS= read -r x; do
            [ -n "$x" ] || continue
            XARGS+=("--exclude-child=^$x\$")
            [ "$(kids_count "$x")" -gt 0 ] && XARGS+=("--exclude-child=^$x/")
        done <<<"${B_EXCL[$i]}"
    done
}
XARGS=()

# PRZYGOTOWANIE NOŚNIKA (uwaga 15, 2026-10-08): pusty dysk -> pula repliki, przez wsad
# prepare-media (zpool create -m none -o failmode=continue, zfs create POOL/BAZA, export).
# Dwie drogi, jeden czasownik: nowy nośnik (pula i baza do wpisania) albo kolejny dysk
# TEJ repliki (rotacja: ta sama pula i baza, brama rozróżnia dyski po GUID).
# 0 = przygotowano (PREP_DST), 1 = wstecz.
prep_media() {   # <pula> <baza> -> PREP_DST, PREP_GUID ; 0 = sformatowany, 1 = wstecz
    # P5 (właściciel 2026-10-09): bez pytań o nazwy -- pula nazywa się sama (<host>-<replika>
    # albo pula tej repliki), baza zawsze "replica". Dysk pamiętany po ID puli (GUID).
    local pool="$1" base="$2" items=() id sz model serial onit dev
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
    wt --title "Replika $NAME -- który dysk sformatować?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --menu "Dyski, których nic nie używa. Wybrany zostanie WYCZYSZCZONY." "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
       "${items[@]}" || return 1
    dev="$WT_OUT"
    "$ZB" prepare-media "$pool" "$dev" --base="$base" >"$TMPD/prep.plan" 2>&1
    if ! grep -q '^PLAN' "$TMPD/prep.plan"; then
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(grep -E 'FATAL' "$TMPD/prep.plan" | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    yesno_text "$TMPD/prep.plan" "Replika $NAME -- formatowanie nośnika" "Sformatuj (KASUJE dysk)" "Wstecz" --defaultno || return 1
    info "Replika $NAME -- nośnik" "Formatuję $dev..."
    if ! "$ZB" prepare-media "$pool" "$dev" --base="$base" --yes >"$TMPD/prep.log" 2>&1; then
        wt --title "Formatowanie nie wyszło" --msgbox "$(tail -4 "$TMPD/prep.log" | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    PREP_DST="$pool/$base"
    PREP_GUID="$(sed -n 's/^guid=//p' "$TMPD/prep.log" | tr -dc '0-9' | head -c 40)"
    return 0
}
guid_of_pool() {   # <pula> -> ID puli: zaimportowanej z zpool get, w slocie ze skanu importu
    local g
    g=$(zpool get -H -o value guid "$1" 2>/dev/null) && [ -n "$g" ] && { echo "$g"; return 0; }
    zpool import 2>/dev/null | awk -v p="$1" '$1=="pool:" {inp=($2==p)} inp && $1=="id:" {print $2; exit}'
}
add_guid() {   # <id> -> GUIDS bez powtórzeń
    [ -n "$1" ] || return 0
    case ",$GUIDS," in *",$1,"*) ;; *) GUIDS="${GUIDS:+$GUIDS,}$1" ;; esac
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
    2)  # co kopiować -- TEN SAM koszyk co w kreatorze relacji (uwaga 13, 2026-10-08)
        if [ "${#T_NAME[@]}" -eq 0 ]; then
            info "Replika $NAME" "Czytam datasety tego hosta..."
            if ! "$ZB" list-datasets --json >"$TMPD/ds.json" 2>"$TMPD/ds.err" || ! basket_tree_from_json "$TMPD/ds.json"; then
                wt --title "Nie udało się pobrać listy" --msgbox "list-datasets:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
                clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1
            fi
            [ -n "$SRCS" ] && basket_from_replica
        fi
        if ! basket_step; then
            [ "$EDIT" -eq 1 ] && { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }
            step=1; continue
        fi
        SRCS="$(IFS=,; printf '%s' "${B_ROOT[*]}")"; REC=yes; basket_xargs
        step=25 ;;
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
    3)  # rodzaj nośnika -- PRZED wyborem nośnika (P5, uwaga 7): od niego zależy lista
        wt --title "Replika $NAME -- 4/6 rodzaj nośnika" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$MEDIA" \
           --menu "Wymienny: każdy bieg importuje pulę i eksportuje ją po kopii (dysk można wyjąć).\nStały: pula jest zawsze w maszynie (np. osobna pula w mirrorze), bez importu/eksportu." 12 "$W" 2 \
           removable "wymienny (USB, dysk do sejfu)" fixed "stały (inna pula w tej maszynie)" || { step=25; continue; }
        MEDIA="$WT_OUT"; [ "$MEDIA" = fixed ] && GUIDS=""
        step=4 ;;
    4)  # nośnik -- tylko PODŁĄCZONY (uwaga 7: "wykluczamy definicje ad-hoc")
        # Czytane przy KAZDYM wejsciu (uwaga 14, 2026-10-08): dysk podpiety w trakcie kreatora
        # nie pojawial sie po "Wstecz", bo lista byla zrobiona raz, na starcie.
        zpool list -H -o name 2>/dev/null >"$TMPD/pools.here"
        zpool import 2>/dev/null | awk '$1=="pool:"{print $2}' >"$TMPD/pools.slot"
        cur="${DST%%/*}"; items=(); seen=""
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case ",$SRCS," in *",$p,"*|*",$p/"*) continue ;; esac   # pula źródła nie jest nośnikiem
            items+=("$p" "$p  dysk podłączony$([ "$p" = "$cur" ] && echo ' (obecny)')"); seen="$seen|$p|"
        done <"$TMPD/pools.here"
        # Stały nośnik jest zawsze zaimportowany; dyski w slocie tylko dla wymiennego.
        if [ "$MEDIA" = removable ]; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue; case "$seen" in *"|$p|"*) continue ;; esac
                items+=("$p" "$p  dysk w slocie$([ "$p" = "$cur" ] && echo ' (obecny)')"); seen="$seen|$p|"
            done < <(sort -u "$TMPD/pools.slot")
        fi
        # Zmiana repliki, której dysku teraz nie ma: zostaje przy swoim (bez wpisywania).
        if [ "$EDIT" -eq 1 ] && [ -n "$cur" ]; then
            case "$seen" in *"|$cur|"*) ;; *) items+=("$cur" "$cur  obecny dysk repliki (teraz nieobecny)") ;; esac
        fi
        # FORMATOWANIE NIGDY NICZEGO NIE WYŁĄCZA (właściciel 2026-10-09): nowa replika --
        # nowy nośnik; zmiana wymiennej -- kolejny dysk tej repliki (ta sama pula, dyski
        # równorzędne, do starego wraca się wkładając go); zmiana stałej -- nic.
        if [ "$EDIT" -eq 0 ]; then
            items+=(__prep__ "Sformatuj nowy nośnik (dysk zostanie wyczyszczony)")
        elif [ "$MEDIA" = removable ] && [ -n "$cur" ]; then
            items+=(__add__ "Dodaj kolejny dysk do tej repliki (zostanie sformatowany)")
        fi
        def="${cur:-__prep__}"
        wt --title "Replika $NAME -- 5/6 nośnik" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "Nośnik musi być podłączony. Kopia ląduje pod  <pula>/replica/<dataset źródła>." "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || { step=3; continue; }
        pool="$WT_OUT"
        if [ "$pool" = __prep__ ]; then
            np="$(hostname -s 2>/dev/null || hostname)-$NAME"; np="$(printf '%s' "$np" | tr -c 'A-Za-z0-9._:\n-' '-')"
            prep_media "$np" replica || continue
            DST="$PREP_DST"; GUIDS=""; add_guid "$PREP_GUID"; step=5; continue
        fi
        if [ "$pool" = __add__ ]; then
            prep_media "$cur" "${DST#*/}" || continue
            add_guid "$PREP_GUID"
            wt --title "Kolejny dysk gotowy" --msgbox "Dysk dopisany do repliki '$NAME' (ID puli $PREP_GUID).\nDyski są równorzędne: replika kopiuje na ten, który jest włożony.\nDo slotu wkładaj JEDEN naraz. Zapisze się po WYKONAJ w planie." 11 "$W"
            step=5; continue
        fi
        if [ "$pool" = "$cur" ]; then
            d="$DST"
        else
            d="$pool/replica"
        fi
        if grep -qxF "$pool" "$TMPD/pools.here" && ! zfs list -H -o name "$d" >/dev/null 2>&1; then
            wt --title "Brak $d" --yes-button "Utwórz" --no-button "Wstecz" \
               --yesno "Pula '$pool' jest zaimportowana, ale nie ma na niej '$d'.\nUtworzyć go teraz (zfs create -p $d)? Tylko na dysku przeznaczonym na replikę." 10 "$W" || continue
            zfs create -p "$d" 2>"$TMPD/zc.err" || { wt --title "zfs create nie wyszedł" --msgbox "$(tail -3 "$TMPD/zc.err")" 10 "$W"; continue; }
        fi
        # ID dysku (P5): inna pula = nowa tożsamość; ta sama -- obecny dysk dopisany,
        # jeśli go jeszcze nie ma (replika sprzed P5 dostaje ID przy pierwszej zmianie).
        if [ "$MEDIA" = removable ]; then
            [ "$pool" = "$cur" ] || GUIDS=""
            add_guid "$(guid_of_pool "$pool")"
        fi
        DST="$d"; step=5 ;;
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
        # Okno B (P5, uwaga 6): ZAWSZE dla wymiennego z harmonogramem -- "po włożeniu" jest
        # ustawieniem TEJ repliki (on_insert), nie hosta. Reguła udev (jedna na host)
        # zakładana albo odnawiana, gdy potrzebna.
        TRIG=no
        if [ "$MEDIA" = removable ]; then
            if [ "$SCHED" != on-insert ]; then
                _dn=""; [ "$ONINS" = yes ] || _dn="--defaultno"
                if wt --title "Replika $NAME -- także po włożeniu?" --yes-button "Tak" --no-button "Nie" $_dn \
                   --yesno "Uruchamiać kopię także od razu po włożeniu dysku tej repliki?\n\nTak: włożony dysk -- kopia od razu, potem dalej wg harmonogramu.\nNie: tylko wg harmonogramu. Inny dysk -- nic się nie dzieje." 11 "$W"; then ONINS=yes; else ONINS=no; fi
            fi
            { [ "$SCHED" = on-insert ] || [ "$ONINS" = yes ]; } && [ "$RULE_HERE" != yes ] && TRIG=yes
        fi
        step=6 ;;
    6)  # plan
        ARGV=("$ZB" add-replica "$NAME" "--source=$SRCS" "--dst=$DST" "--schedule=$SCHED")
        [ "$MEDIA" = fixed ] && ARGV+=(--fixed) || ARGV+=(--removable)
        [ "$REC" = yes ] && ARGV+=(--recursive=yes) || ARGV+=(--recursive=no)
        ARGV+=(${XARGS[@]+"${XARGS[@]}"})
        [ "$PASSIVE" = yes ] && ARGV+=(--passive)
        if [ "$MEDIA" = removable ]; then
            [ -n "$GUIDS" ] && ARGV+=("--media-guid=$GUIDS")
            [ "$SCHED" != on-insert ] && ARGV+=("--on-insert=$ONINS")
        fi
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
            echo "Źródła:     ${SRCS//,/, }  (z tym, co pod nimi jest i powstanie)"
            for _i in "${!B_ROOT[@]}"; do
                [ -n "${B_EXCL[$_i]}" ] && echo "Pomijane:   $(printf '%s' "${B_EXCL[$_i]}" | paste -sd, - | sed 's/,/, /g')"
            done
            echo "Migawki:    $([ "$PASSIVE" = yes ] && echo "istniejące -- bez własnych" || echo "własne, przedrostek replica_")"
            echo "Nośnik:     $DST  ($([ "$MEDIA" = fixed ] && echo stały || echo wymienny))"
            if [ "$MEDIA" = removable ]; then
                if [ -n "$GUIDS" ]; then echo "Dyski:      $(printf '%s' "$GUIDS" | tr ',' '\n' | grep -c .) (po ID puli: ${GUIDS//,/, }) -- inny dysk z tą nazwą puli nie zostanie użyty"
                else echo "Dyski:      rozpoznawane po nazwie puli (ID nieznane -- dysk nieobecny)"; fi
            fi
            echo "Kiedy:      $([ "$SCHED" = on-insert ] && echo "tylko po włożeniu dysku" || echo "$SCHED")"
            if [ -n "$MONDAYS" ]; then echo "Ostrzeżenie: po $MONDAYS dniach bez kopii, alarm po $(( (MONDAYS * 3 + 1) / 2 ))"
            elif [ "$SCHED" = on-insert ]; then echo "Ostrzeżenie: brak (replika po włożeniu bez progu)"
            else echo "Ostrzeżenie: z harmonogramu (dobowo 2/4 dni, tygodniowo 9/14, miesięcznie 35/45)"; fi
            if [ "$MEDIA" = removable ]; then
                if [ "$SCHED" = on-insert ] || [ "$ONINS" = yes ]; then
                    if [ "$TRIG" = yes ]; then
                        echo "Po włożeniu: kopia rusza od razu -- krok: reguła udev ZOSTANIE $([ "$RULE_HERE" = old ] && echo ODNOWIONA || echo ZAŁOŻONA)"
                        echo "             (install-media-trigger --install; jedna na host)"
                    else
                        echo "Po włożeniu: kopia rusza od razu (reguła udev jest na hoście)"
                    fi
                else
                    echo "Po włożeniu: nic -- kopia tylko wg harmonogramu"
                fi
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
        yesno_text "$TMPD/plan2.txt" "Replika $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || { step=5; continue; }
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
            elif [ "$MEDIA" = removable ] && [ "$ONINS" = yes ]; then _first="po włożeniu dysku, wg harmonogramu albo teraz: F7 na F6"
            else _first="wg harmonogramu albo teraz: F7 na F6"; fi
            echo "=== GOTOWE: replika '$NAME' zainstalowana (rc=$RC). Pierwsza kopia: $_first. Enter = dalej"
        else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- nic nie zainstalowano; powód w linii FATAL powyżej. Enter = dalej"; fi
        [ -t 0 ] && read -r _
        exit "$RC" ;;
    esac
done
