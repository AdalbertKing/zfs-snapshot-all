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
                     r.get("media_guids") or "-", r.get("on_insert") or "no", r.get("keep") or "-", r.get("raw") or "no", r.get("history") or "all"]))
PYEOF
SRCS=""; DST=""; SCHED="0 22 * * *"; MEDIA=removable; REC=yes; TRIG=no; UNTRIG=no; MONDAYS=""; PASSIVE=""
GUIDS=""; ONINS=no; CURGUIDS=""; KEEP=""; RAW=no; HIST=all; ENGINE_ONLY=0
RULES="${ZFS_REPLICA_RULES:-/etc/udev/rules.d/90-zfs-replica.rules}"
if [ "$EDIT" -eq 1 ]; then
    if ! IFS=$'\t' read -r _n SRCS DST SCHED MEDIA REC CURWARN CURPFX CURX CURGUIDS ONINS KEEP RAW HIST < <(awk -F'\t' -v n="$NAME" '$1==n' "$TMPD/rep.tsv"); then
        wt --title "Nie ma repliki '$NAME'" --msgbox "W configu tego kolektora nie ma [replica:$NAME].\n(list-replicas: $(tail -1 "$TMPD/rep.err" 2>/dev/null))" 10 "$W"
        exit 1
    fi
    [ "$MEDIA" = - ] && MEDIA=fixed
    case "$REC" in yes|1|true) REC=yes ;; *) REC=no ;; esac
    [ "${CURPFX:-}" = - ] && PASSIVE=yes || PASSIVE=no
    [ "${CURGUIDS:-}" = - ] && CURGUIDS=""; GUIDS="$CURGUIDS"
    [ "${ONINS:-}" = yes ] || ONINS=no
    [ "${KEEP:-}" = - ] && KEEP=""
    [ "${RAW:-}" = yes ] || RAW=no
    case "${HIST:-}" in ''|-) HIST=all ;; esac
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
title() { rtitle 2 "$2"; }
# Kampania 2026-10-22: "6/6 kiedy" w oknie ZMIANY repliki nic nie mówi -- numer kroku tylko
# przy zakładaniu; w zmianie sam krok.
rtitle() {   # <nr kroku> <tekst>
    if [ "${EDIT:-0}" -eq 1 ]; then printf 'Zmiana repliki %s: %s' "${NAME:-}" "$2"
    else printf 'Replika %s -- %s/6 %s' "${NAME:-}" "$1" "$2"; fi
}
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
# U67 (owner 2026-10-21): zaznaczona cała pula = wszystkie datasety pod nią, rekurencyjnie.
# Silnik (gen-cron) bierze datasety, nie korzeń puli, więc pula staje się listą datasetów
# leżących bezpośrednio pod nią -- każdy z całym drzewem pod sobą (REC=yes). Dataset
# pominięty w koszyku w całości odpada; pominięcia głębiej idą za swoim datasetem.
# H-7 (kampania 2026-10-21): pula nośnika INNEJ repliki (replab) była na liście źródeł nowej.
# Nośnik wymienny = cała jego pula; nośnik stały = katalog docelowy z poddrzewem. Z listy
# datasetów (ds.json) znikają, zanim powstanie z niej drzewo.
drop_replica_media() {
    "$PY" - "$TMPD/ds.json" "$TMPD/rep.json" <<'PYEOF' || true
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    r = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception:
    sys.exit(0)
hide = []
for x in r.get("replicas") or []:
    dst = (x.get("dst") or "").strip("/")
    if not dst:
        continue
    hide.append(dst.split("/")[0] if x.get("media") == "removable" else dst)
if hide:
    d["datasets"] = [x for x in d.get("datasets") or []
                     if not any(x.get("name") == h or (x.get("name") or "").startswith(h + "/") for h in hide)]
    json.dump(d, open(sys.argv[1], "w", encoding="utf-8"))
PYEOF
}
pool_roots_to_children() {   # B_ROOT/B_EXCL -> SRC_ROOT/SRC_EXCL bez korzeni puli; 1 + POOL_EMPTY, gdy pula pusta
    # Koszyk (B_ROOT) zostaje taki, jak go zaznaczono: Wstecz do drzewa pokazuje całą pulę
    # zaznaczoną, nie "[-] część" (H-1, kampania na żywo 2026-10-21).
    local -a nr=() ne=()
    local i r c x e n list
    POOL_NOTE=""; POOL_EMPTY=""
    for i in "${!B_ROOT[@]}"; do
        r="${B_ROOT[$i]}"
        case "$r" in */*) nr+=("$r"); ne+=("${B_EXCL[$i]}"); continue ;; esac
        n=0; list=""
        for c in ${T_NAME[@]+"${T_NAME[@]}"}; do
            case "$c" in "$r"/*/*) continue ;; "$r"/*) ;; *) continue ;; esac
            printf '%s\n' "${B_EXCL[$i]}" | grep -qxF -- "$c" && continue
            e=""
            while IFS= read -r x; do case "$x" in "$c"/*) e="$e${e:+$'\n'}$x" ;; esac; done <<<"${B_EXCL[$i]}"
            nr+=("$c"); ne+=("$e"); n=$((n + 1)); list="$list  $c\n"
        done
        [ "$n" -gt 0 ] || { POOL_EMPTY="$r"; return 1; }
        POOL_NOTE="${POOL_NOTE}Cała pula $r = $n datasetów bezpośrednio pod nią, każdy razem z tym, co pod nim:\n${list}\nDataset założony później BEZPOŚREDNIO pod pulą $r trzeba dopisać zmianą repliki\n(niżej -- pod tymi datasetami -- dojdzie sam).\n"
    done
    SRC_ROOT=(${nr[@]+"${nr[@]}"}); SRC_EXCL=(${ne[@]+"${ne[@]}"})
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
# prepare-media (zpool create -m none -o failmode=continue -O compression=zstd, zfs create POOL/BAZA, export).
# Dwie drogi, jeden czasownik: nowy nośnik (pula i baza do wpisania) albo kolejny dysk
# TEJ repliki (rotacja: ta sama pula i baza, brama rozróżnia dyski po GUID).
# 0 = przygotowano (PREP_DST), 1 = wstecz.
prep_media() {   # <pula> <baza> -> PREP_DST, PREP_GUID ; 0 = sformatowany, 1 = wstecz
    # P5 (właściciel 2026-10-09): bez pytań o nazwy -- pula nazywa się sama (<host>-<replika>
    # albo pula tej repliki), baza "replica" (kolejny dysk: baza repliki). Dysk pamiętany po ID puli (GUID).
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
    # W19(b) (właściciel 2026-10-11, "ma być proste"): jedno pytanie, domyślnie Tak.
    # Kolejny dysk puli, która ma już klucz, jest szyfrowany tym samym kluczem bez pytania
    # -- dyski jednej repliki muszą dać się czytać tak samo.
    local enc=() kf="${ZFS_MEDIA_KEY_DIR:-/etc/zfs-snapshot-all/keys}/$pool.key"
    if [ -s "$kf" ]; then
        enc=(--encrypt)
    elif wt --title "Replika $NAME -- szyfrowanie" --yes-button "Tak" --no-button "Nie" \
           --yesno "Szyfrować nośnik?\n\nGdy dysk zginie albo zostanie skradziony, nikt nie odczyta kopii.\nKlucz zostaje na tym serwerze; kopie robią się same, bez hasła.\nPo formatowaniu pokażę klucz -- zapisz go poza tym serwerem." 12 "$W"; then
        enc=(--encrypt)
    fi
    "$ZB" prepare-media "$pool" "$dev" --base="$base" "${enc[@]}" >"$TMPD/prep.plan" 2>&1
    if ! grep -q '^PLAN' "$TMPD/prep.plan"; then
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(grep -E 'FATAL' "$TMPD/prep.plan" | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    yesno_text "$TMPD/prep.plan" "Replika $NAME -- formatowanie nośnika" "Sformatuj (KASUJE dysk)" "Wstecz" --defaultno || return 1
    info "Replika $NAME -- nośnik" "Formatuję $dev..."
    if ! "$ZB" prepare-media "$pool" "$dev" --base="$base" "${enc[@]}" --yes >"$TMPD/prep.log" 2>&1; then
        wt --title "Formatowanie nie wyszło" --msgbox "$(tail -4 "$TMPD/prep.log" | fold -s -w $((W - 6)))" 12 "$W"
        return 1
    fi
    PREP_DST="$pool/$base"
    PREP_GUID="$(sed -n 's/^guid=//p' "$TMPD/prep.log" | tr -dc '0-9' | head -c 40)"
    local key; key="$(sed -n 's/^key=//p' "$TMPD/prep.log" | head -1)"
    if [ -n "$key" ]; then
        wt --title "Klucz nośnika $pool -- ZAPISZ GO" --msgbox "Nośnik jest zaszyfrowany. Klucz:\n\n  $key\n\nZapisz go POZA tym serwerem (np. w sejfie haseł). Bez klucza i bez tego\nserwera kopii z dysku nie odczytasz. Na F6 pokażesz go znowu (F8).\nPlik na serwerze: $(sed -n 's/^keyfile=//p' "$TMPD/prep.log" | head -1)" 14 "$W"
    fi
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
# USTAWIENIA SILNIKA REPLIKI (właściciel 2026-10-12, "tak, rób okno ustawień silnika dla
# repliki"): to samo okno co dla relacji (W16), trzy wiersze, które dla repliki mają sens --
# kopia jest lokalna, więc bez kompresji, szyfru i limitu łącza. Zmiana idzie tym samym
# add-replica co cały kreator (plan, potem WYKONAJ), z pozostałymi ustawieniami bez zmian.
eng_hist_words() { case "$1" in all) echo "wszystkie migawki pomiędzy" ;; newest) echo "tylko różnica do najnowszej" ;; auto:*) echo "auto (po ${1#auto:} odstępach tylko różnica)" ;; *) echo "$1" ;; esac; }
replica_engine() {   # 0 = coś zmienione (ARGV zbuduje krok 6), 1 = Wstecz bez zmian
    local p_pas="$PASSIVE" p_keep="$KEEP" p_h="$HIST" items v N
    while :; do
        geom
        items=(mig "Migawki          $([ "$p_pas" = yes ] && echo "cała historia (istniejące)" || echo "tylko stan na chwilę kopii (własne replica_)")")
        # X10 (właściciel 2026-10-12/14): sprzecznych ustawień nie da się wybrać. "Cała historia"
        # przenosi wszystkie istniejące migawki, a "N ostatnich zdjęć" -- tylko zdjęcia replica_
        # (silnik wysyła wtedy samo najnowsze: pośrednie trafiałyby na dysk bez sprzątania).
        # W obu wiersz Historia nie ma czego wybierać.
        [ "$p_pas" != yes ] && [ -z "$p_keep" ] && items+=(hist "Historia         $(eng_hist_words "$p_h")$([ "$p_h" = all ] && echo ' (fabryczne)')")
        [ "$p_pas" = yes ] || items+=(disk "Na dysku         $([ -n "$p_keep" ] && echo "$p_keep ostatnich zdjęć replica_ (pośrednie nie trafiają)" || echo "odbicie kolektora (fabryczne)")")
        [ "$RAW" = yes ] && items+=(raw "Szyfrowane       wysyłka zaszyfrowana (raw)")
        items+=(__done__ "Gotowe")
        wt --title "Ustawienia silnika: replika $NAME" --ok-button "Wybierz" --cancel-button "Wstecz" --notags --default-item __done__ \
           --menu "Jak replika przenosi kopie na dysk." "$(fit $((${#items[@]} / 2 + 2)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || return 1
        case "$WT_OUT" in
            mig)
                wt --title "Migawki" --ok-button "Wybierz" --cancel-button "Wstecz" --notags --default-item "$([ "$p_pas" = yes ] && echo passive || echo own)" \
                   --menu "Jakie migawki ma przenosić replika?" 10 "$W" 2 \
                   passive "Cała historia -- migawki, które już są (wrócisz do wczoraj, tydzień temu…); więcej miejsca" \
                   own "Tylko stan na chwilę kopii -- jedna migawka replica_ na dysku; najmniej miejsca" || continue
                [ "$WT_OUT" = passive ] && { p_pas=yes; p_keep=""; p_h=all; } || p_pas=no ;;
            hist)
                wt --title "Historia" --ok-button "Wybierz" --cancel-button "Wstecz" --notags --default-item "${p_h%%:*}" \
                   --menu "Co przenosić, gdy na dysku brakuje kilku migawek." 11 "$W" 3 \
                   all    "Wszystkie migawki pomiędzy -- pełna historia na dysku" \
                   newest "Tylko różnica do najnowszej -- mniej miejsca, bez historii pośredniej" \
                   auto   "Auto -- wszystkie, a przy dużej zaległości tylko różnica" || continue
                if [ "$WT_OUT" = auto ]; then
                    N=3; case "$p_h" in auto:*) N="${p_h#auto:}" ;; esac
                    wt --title "Historia: auto" --ok-button "Dalej" --cancel-button "Wstecz" \
                       --inputbox "Po ilu odstępach zaległości przejść na samą różnicę (1-999)?" 9 "$W" "$N" || continue
                    case "$WT_OUT" in ''|*[!0-9]*|0*) wt --title "Zła liczba" --msgbox "'$WT_OUT' -- liczba od 1 do 999." 8 "$W"; continue ;; esac
                    [ "${#WT_OUT}" -le 3 ] || { wt --title "Zła liczba" --msgbox "'$WT_OUT' -- liczba od 1 do 999." 8 "$W"; continue; }
                    p_h="auto:$WT_OUT"
                else
                    p_h="$WT_OUT"
                fi ;;
            disk)
                wt --title "Na dysku" --ok-button "Wybierz" --cancel-button "Wstecz" --notags --default-item "$([ -n "$p_keep" ] && echo keep || echo mirror)" \
                   --menu "Co ma zostawać na dysku repliki?" 10 "$W" 2 \
                   mirror "Odbicie kolektora -- dysk trzyma to, co kolektor" \
                   keep "Trzymaj N ostatnich kopii -- własna historia dysku, niezależna od kolektora" || continue
                if [ "$WT_OUT" = keep ]; then
                    wt --title "Ile kopii na dysku" --ok-button "Dalej" --cancel-button "Wstecz" \
                       --inputbox "Ile ostatnich kopii (migawek replica_) ma zostawać na dysku?" 9 "$W" "${p_keep:-12}" || continue
                    case "$WT_OUT" in ''|*[!0-9]*|0*) wt --title "Zła liczba" --msgbox "'$WT_OUT' -- liczba całkowita większa od 0." 8 "$W"; continue ;; esac
                    p_keep="$WT_OUT"; p_h=all
                else
                    p_keep=""
                fi ;;
            raw)
                wt --title "Wysyłka zaszyfrowana" --msgbox "Źródło repliki jest zaszyfrowane i kopie idą zaszyfrowane (raw).\nTego nie zmienia się w działającej replice -- zmiana to nowa kopia od zera." 10 "$W"
                continue ;;
            __done__)
                [ "$p_pas" = "$PASSIVE" ] && [ "$p_keep" = "$KEEP" ] && [ "$p_h" = "$HIST" ] && return 1
                PASSIVE="$p_pas"; KEEP="$p_keep"; HIST="$p_h"
                return 0 ;;
        esac
    done
}
step=1
# ZMIANA REPLIKI = JEDNA LISTA (U8, właściciel 2026-10-18: "musiałem przejść całą ścieżkę
# repliki, żeby wybrać »nie« przy »uruchom po włożeniu« -- kreator jest do bani"). Lista
# pokazuje OBECNE wartości; pozycja uruchamia tylko swój krok kreatora i wraca tutaj (ONE),
# "Po włożeniu dysku" przełącza się od razu, "Zapisz zmiany" = plan i WYKONAJ (krok 6,
# ta sama komenda add-replica co w kreatorze).
MENU=0; ONE=""
trig_calc() {    # TRIG/UNTRIG: czy plan zakłada albo zdejmuje regułę udev "po włożeniu"
    TRIG=no
    if [ "$MEDIA" = removable ]; then
        { [ "$SCHED" = on-insert ] || [ "$ONINS" = yes ]; } && [ "$RULE_HERE" != yes ] && TRIG=yes
    fi
    # W DRUGĄ STRONĘ (właściciel 2026-10-18: "skoro możemy włączać, chcemy móc
    # wyłączyć"): reguła jest jedna na host, więc schodzi, gdy po tej zmianie
    # ŻADNA replika -- ta ani inne -- nie rusza po włożeniu dysku.
    UNTRIG=no
    if [ "$RULE_HERE" != no ] && [ "$TRIG" = no ] \
       && ! { [ "$MEDIA" = removable ] && { [ "$SCHED" = on-insert ] || [ "$ONINS" = yes ]; }; } \
       && ! awk -F'\t' -v n="$NAME" '$1 != n && ($4 == "on-insert" || $11 == "yes") { f = 1 } END { exit !f }' "$TMPD/rep.tsv"; then
        UNTRIG=yes
    fi
}
sched_words() {
    case "$1" in
        "0 22 * * *") echo "codziennie 22:00" ;; "0 22 * * 5") echo "co tydzień, piątek 22:00" ;;
        "0 22 1 * *") echo "co miesiąc, 1. dnia 22:00" ;; on-insert) echo "tylko po włożeniu dysku" ;;
        *) echo "cron: $1" ;;
    esac
}
one_allows() {   # <krok> -> 0, gdy krok należy do pozycji wybranej z listy
    case "$ONE:$1" in
        zrodla:2|dysk:25|dysk:26|nosnik:3|nosnik:4|kiedy:5|zapisz:6) return 0 ;;
    esac
    return 1
}
edit_menu() {    # -> step ustawiony na pierwszy krok pozycji (albo exit)
    local n _src np
    # E-1 (kampania 2026-10-22): ta sama karta co zmiana relacji (U65) -- nazwa w nagłówku,
    # zmieniona pozycja z '*' i "[zmiana]", pod kreską tylko akcje, licznik przy zapisie,
    # Wstecz przy zmianach pyta. Stan wyjściowy zapamiętany przy pierwszym wejściu.
    sig() { case "$1" in
        zrodla) printf '%s|%s' "$SRCS" "${XARGS[*]-}" ;; dysk) printf '%s|%s' "$PASSIVE" "$KEEP" ;;
        nosnik) printf '%s|%s|%s' "$DST" "$MEDIA" "$GUIDS" ;; kiedy) printf '%s' "$SCHED" ;;
        onins) printf '%s' "$ONINS" ;; silnik) printf '%s' "$HIST" ;; esac; }
    if [ -z "${O_SIG_SET:-}" ]; then
        for n in zrodla dysk nosnik kiedy onins silnik; do printf -v "O_SIG_$n" '%s' "$(sig "$n")"; done
        O_SIG_SET=1
    fi
    ch() { local o="O_SIG_$1"; [ "$(sig "$1")" != "${!o}" ]; }
    rp_row() {   # <tag> <nazwa> <wartość>
        CARD_TAGS+=("$1"); CARD_FIXED+=(0)
        if ch "$1"; then CARD_NAMES+=("* $2"); CARD_VALUES+=("$3 [zmiana]"); np=$((np + 1))
        else CARD_NAMES+=("  $2"); CARD_VALUES+=("$3"); fi
    }
    while :; do
        n=$(printf '%s' "$SRCS" | tr ',' '\n' | grep -c .)
        _src="${SRCS%%,*}"; [ "$n" -gt 1 ] && _src="$_src (+$((n - 1)))"
        CARD_TAGS=(); CARD_NAMES=(); CARD_VALUES=(); CARD_FIXED=(); np=0
        rp_row zrodla "Źródła" "$_src"
        rp_row dysk "Na dysku" "$([ "$PASSIVE" = yes ] && echo "cała historia (istniejące migawki)" || { [ -n "$KEEP" ] && echo "własne, $KEEP ostatnich" || echo "własne, odbicie kolektora"; })"
        rp_row nosnik "Nośnik" "$DST ($([ "$MEDIA" = fixed ] && echo stały || echo wymienny))"
        rp_row kiedy "Kiedy" "$(sched_words "$SCHED")"
        if [ "$MEDIA" = removable ] && [ "$SCHED" != on-insert ]; then
            rp_row onins "Po włożeniu" "$([ "$ONINS" = yes ] && echo "kopia minutę po włożeniu dysku" || echo "nic, tylko wg harmonogramu")"
        elif ch onins; then np=$((np + 1)); fi
        rp_row silnik "Silnik" "historia: $(eng_hist_words "$HIST")"
        CARD_ACT_TAGS=(zapisz restart)
        if [ "$np" -gt 0 ]; then CARD_ACT_LABELS=("ZAPISZ ZMIANY ($np) -- najpierw plan do potwierdzenia")
        else CARD_ACT_LABELS=("Zapisz zmiany (brak zmian)"); fi
        CARD_ACT_LABELS+=("Zacznij od nowa na tym dysku (pełna kopia)…")
        card_menu "Zmiana repliki $NAME" "replika $NAME   kolektor $(hostname)\nCo zmienić? Zapis dopiero w \"Zapisz zmiany\"." "${LAST_ITEM:-zrodla}" "Wstecz" || {
            if [ "$np" -gt 0 ]; then
                wt --title "Porzucić zmiany?" --yes-button "Porzuć" --no-button "Wróć" --defaultno \
                   --yesno "Na liście czeka zmian: $np. Wyjść bez zapisu?" 8 "$W"
                [ $? -ne 0 ] && continue   # Wróć albo Esc = zostań
            fi
            clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }
        LAST_ITEM="$WT_OUT"
        case "$WT_OUT" in
            __sep__) LAST_ITEM=zapisz; continue ;;
            zrodla) ONE=zrodla; step=2; return 0 ;;
            dysk)   ONE=dysk; step=25; return 0 ;;
            nosnik) ONE=nosnik; step=3; return 0 ;;
            kiedy)  ONE=kiedy; step=5; return 0 ;;
            zapisz) ONE=zapisz; trig_calc; step=6; return 0 ;;
            onins)  [ "$ONINS" = yes ] && ONINS=no || ONINS=yes ;;
            silnik) replica_engine || : ;;
            restart)
            # W18 (właściciel 2026-10-12): gdy łańcuch repliki się zerwał (relację usunięto
            # i założono od nowa), jedyna droga to pełna kopia. Nowa obok starej, stara znika
            # dopiero po udanej nowej -- plan i WYKONAJ, jak każda zmiana.
            info "Replika $NAME" "Liczę plan..."
            "$ZB" replica-restart "$NAME" >"$TMPD/rs.txt" 2>&1 || { wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(verb_refusal "$TMPD/rs.txt")" 10 "$W"; continue; }
            { echo "PLAN -- nic jeszcze nie zostało zmienione:"; echo; grep -v '^plan only' "$TMPD/rs.txt"; echo
              echo "Komenda:  $(shq "$ZB") replica-restart $NAME --yes"; } >"$TMPD/rs2.txt"
            yesno_text "$TMPD/rs2.txt" "Replika $NAME -- zacznij od nowa" "WYKONAJ" "Wstecz" --defaultno || continue
            : >"$TMPD/run.log"
            RC=0; run_progress "Replika $NAME: zacznij od nowa" "$TMPD/run.log" "$ZB" replica-restart "$NAME" --yes || RC=$?
            [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
            if [ "$RC" -eq 0 ]; then
                echo "GOTOWE: replika '$NAME' zaczęła od nowa (rc=0)." >"$TMPD/result.txt"
                result_box "Replika $NAME: zacznij od nowa: GOTOWE" 0 "$TMPD/run.log" "$(cat "$TMPD/result.txt")"
            else
                echo "Nie udało się -- stara kopia na dysku została." >"$TMPD/result.txt"
                result_box "Replika $NAME: zacznij od nowa" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
            fi
            exit "$RC" ;;
        esac
    done
}
if [ "$EDIT" -eq 1 ]; then
    MENU=1
    # Plan potrzebuje wzorców wyjątków (-X) z drzewa datasetów, jak po koszyku.
    info "Replika $NAME" "Czytam datasety tego hosta..."
    if ! "$ZB" list-datasets --json >"$TMPD/ds.json" 2>"$TMPD/ds.err" || ! { drop_replica_media; basket_tree_from_json "$TMPD/ds.json"; }; then
        wt --title "Nie udało się pobrać listy" --msgbox "list-datasets:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
        clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1
    fi
    basket_from_replica; basket_xargs
    # Próg ostrzeżenia repliki "po włożeniu" zostaje, gdy "Kiedy" nie jest ruszane.
    [ "$SCHED" = on-insert ] && case "${CURWARN:-}" in *d) MONDAYS="${CURWARN%d}" ;; esac
    edit_menu
fi
while :; do
    geom
    if [ "$MENU" -eq 1 ] && ! one_allows "$step"; then
        edit_menu
        continue
    fi
    case "$step" in
    1)  # nazwa
        if [ "$EDIT" -eq 1 ]; then step=2; continue; fi
        wt --title "Nowa replika -- 1/6 nazwa" --ok-button "Dalej" --cancel-button "Anuluj" \
           --inputbox "Nazwa repliki (litery, cyfry, . _ -), np. usb1 albo sejf-a.\nTak będzie widoczna na F6, w mailach i w nazwie puli nowego nośnika." 10 "$W" "$NAME" \
           || { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }
        n="${WT_OUT// /}"
        case "$n" in
            '') wt --title "Brak nazwy" --msgbox "Wpisz nazwę repliki, np. usb1." 8 "$W"; continue ;;
            [-.]*|*[!A-Za-z0-9._-]*) wt --title "Zła nazwa" --msgbox "'$WT_OUT' -- tylko litery, cyfry, kropka, myślnik, podkreślenie; na początku nie kropka ani myślnik." 8 "$W"; continue ;;
        esac
        if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/rep.tsv"; then
            wt --title "Nazwa zajęta" --msgbox "Replika '$n' już jest -- zmienisz ją w jej oknie na ekranie Replika." 8 "$W"; continue
        fi
        NAME="$n"; step=2 ;;
    2)  # co kopiować -- TEN SAM koszyk co w kreatorze relacji (uwaga 13, 2026-10-08)
        if [ "${#T_NAME[@]}" -eq 0 ]; then
            info "Replika $NAME" "Czytam datasety tego hosta..."
            if ! "$ZB" list-datasets --json >"$TMPD/ds.json" 2>"$TMPD/ds.err" || ! { drop_replica_media; basket_tree_from_json "$TMPD/ds.json"; }; then
                wt --title "Nie udało się pobrać listy" --msgbox "list-datasets:\n\n$(tail -3 "$TMPD/ds.err")" 12 "$W"
                clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1
            fi
            [ -n "$SRCS" ] && basket_from_replica
        fi
        if ! basket_step; then
            [ "$MENU" -eq 1 ] && { step=0; continue; }
            [ "$EDIT" -eq 1 ] && { clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1; }
            step=1; continue
        fi
        if ! pool_roots_to_children; then
            wt --title "Replika $NAME" --msgbox "Pula $POOL_EMPTY nie ma żadnego datasetu do skopiowania." 8 "$W"
            continue
        fi
        if [ -n "$POOL_NOTE" ]; then
            wt --title "Replika $NAME -- cała pula" --msgbox "$POOL_NOTE" "$(fit "$(printf '%b' "$POOL_NOTE" | grep -c '')")" "$W"
        fi
        SRCS="$(IFS=,; printf '%s' "${SRC_ROOT[*]}")"; REC=yes; basket_xargs
        # ZASZYFROWANE ŹRÓDŁO = WYSYŁKA ZASZYFROWANA (właściciel 2026-10-12): kopia relacji
        # pobrana "raw" leży na kolektorze BEZ klucza i zwykła kopia jej nie odczyta.
        # Tylko dla NOWEJ repliki -- w istniejącej tryb zostaje (zmiana = nowa kopia od zera).
        if [ "$EDIT" -eq 0 ]; then
            RAW=no
            "$PY" - "$TMPD/ds.json" "${B_ROOT[@]}" <<'PYEOF' && RAW=yes
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(1)
roots = sys.argv[2:]
for x in d.get("datasets") or []:
    n, e = x.get("name") or "", (x.get("encryption") or "-")
    if e not in ("off", "-", "") and any(n == r or n.startswith(r + "/") for r in roots):
        sys.exit(0)
sys.exit(1)
PYEOF
        fi
        step=25 ;;
    25) # migawki: własne czy istniejące (uwaga 20, 2026-10-08)
        # Kopie relacji na tym kolektorze dostają migawki od swojego źródła; migawka
        # replica_ postawiona na nich znika przy następnym pobraniu (kopia idzie za
        # źródłem). Dla nich domyślnie: bez własnych migawek.
        def=own; covers_landing && def=passive
        [ "$PASSIVE" = yes ] && def=passive; [ "$PASSIVE" = no ] && def=own
        # W14 (zmierzone pve9b 2026-10-11): na kopiach relacji "własne" działa (przyrost od
        # zakładki), ale na dysku zostaje zawsze JEDNA migawka -- stan z chwili kopii.
        # Właściciel: to też potrzebny tryb ("najmniej miejsca"), więc oba zostają, opisane wprost.
        lead=""; covers_landing && lead="Źródło obejmuje kopie relacji tego kolektora.\n\n"
        wt --title "$(rtitle 3 'migawki')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "${lead}Jakie migawki ma przenosić replika?" "$(fit 9)" "$W" 2 \
           passive "Cała historia -- migawki, które już są (wrócisz do wczoraj, tydzień temu…); więcej miejsca" \
           own "Tylko stan na chwilę kopii -- jedna migawka replica_ na dysku; najmniej miejsca" || { step=2; continue; }
        [ "$WT_OUT" = passive ] && PASSIVE=yes || PASSIVE=no
        [ "$PASSIVE" = yes ] && { KEEP=""; step=3; continue; }
        step=26 ;;
    26) # NA DYSKU: odbicie kolektora czy własne N (W18, właściciel 2026-10-11 -- dysk
        # wkładany raz w miesiącu, 12 stanów wstecz). Tylko przy własnych migawkach.
        def=mirror; [ -n "$KEEP" ] && def=keep
        wt --title "$(rtitle 3 'na dysku')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "Co ma zostawać na dysku repliki?" 11 "$W" 2 \
           mirror "Odbicie kolektora -- dysk trzyma to, co kolektor" \
           keep "Trzymaj N ostatnich kopii -- własna historia dysku, niezależna od kolektora" || { step=25; continue; }
        if [ "$WT_OUT" = mirror ]; then KEEP=""; step=3; continue; fi
        while :; do
            wt --title "Replika $NAME -- ile kopii na dysku" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Ile ostatnich kopii (migawek replica_) ma zostawać na dysku?\nNp. 12 = rok przy dysku wkładanym raz w miesiącu." 10 "$W" "${KEEP:-12}" || { WT_OUT=""; break; }
            case "$WT_OUT" in ''|*[!0-9]*|0*) wt --title "Zła liczba" --msgbox "'$WT_OUT' -- liczba całkowita większa od 0." 8 "$W"; continue ;; esac
            break
        done
        [ -n "$WT_OUT" ] || continue
        KEEP="$WT_OUT"
        step=3 ;;
    3)  # rodzaj nośnika -- PRZED wyborem nośnika (P5, uwaga 7): od niego zależy lista
        wt --title "$(rtitle 4 'rodzaj nośnika')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$MEDIA" \
           --menu "Wymienny: każdy bieg importuje pulę i eksportuje ją po kopii (dysk można wyjąć).\nStały: pula jest zawsze w maszynie (np. osobna pula w mirrorze), bez importu/eksportu." 12 "$W" 2 \
           removable "wymienny (USB, dysk do sejfu)" fixed "stały (inna pula w tej maszynie)" || { [ "$PASSIVE" = yes ] && step=25 || step=26; continue; }
        MEDIA="$WT_OUT"; [ "$MEDIA" = fixed ] && GUIDS=""
        step=4 ;;
    4)  # nośnik -- tylko PODŁĄCZONY (uwaga 7: "wykluczamy definicje ad-hoc")
        # Czytane przy KAZDYM wejsciu (uwaga 14, 2026-10-08): dysk podpiety w trakcie kreatora
        # nie pojawial sie po "Wstecz", bo lista byla zrobiona raz, na starcie.
        zpool list -H -o name 2>/dev/null >"$TMPD/pools.here"
        zpool import 2>/dev/null | awk '$1=="pool:"{print $2}' >"$TMPD/pools.slot"
        cur="${DST%%/*}"; items=(); seen=""
        # Dysk INNEJ repliki nie jest do wyboru (jeden nośnik = jedna replika; czasownik
        # odmawiał dopiero w planie -- kampania 2026-10-09, K45).
        others="$(awk -F'\t' -v n="$NAME" '$1!=n && $3!="-" {split($3,a,"/"); printf "|%s|", a[1]}' "$TMPD/rep.tsv")"
        busy=""
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            case ",$SRCS," in *",$p,"*|*",$p/"*) continue ;; esac   # pula źródła nie jest nośnikiem
            case "$others" in *"|$p|"*) busy="$busy $p"; continue ;; esac
            items+=("$p" "$p  dysk podłączony$([ "$p" = "$cur" ] && echo ' (obecny)')"); seen="$seen|$p|"
        done <"$TMPD/pools.here"
        # Stały nośnik jest zawsze zaimportowany; dyski w slocie tylko dla wymiennego.
        if [ "$MEDIA" = removable ]; then
            while IFS= read -r p; do
                [ -n "$p" ] || continue; case "$seen" in *"|$p|"*) continue ;; esac
                case "$others" in *"|$p|"*) busy="$busy $p"; continue ;; esac
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
            # W12 (właściciel 2026-10-11): dwie pozycje i nic więcej. Zepsuty dysk =
            # Usuń dysk, potem Dodaj dysk (dodanie i tak formatuje).
            items+=(__add__ "Dodaj dysk (włożony zostanie sformatowany)")
            # Ostatniego dysku się nie usuwa -- replika bez dysku to "Usuń replikę".
            case "$GUIDS" in *,*) items+=(__del__ "Usuń dysk z repliki (dane na nim zostają)") ;; esac
        fi
        # Domyślnie dysk, który już jest -- nie formatowanie (kampania 2026-10-19: Enter
        # na tym kroku wybierał "Sformatuj", a następny Enter kasował dysk z pulą).
        def="$cur"
        if [ -z "$def" ]; then
            for ((_k = 0; _k < ${#items[@]}; _k += 2)); do case "${items[$_k]}" in __*) ;; *) def="${items[$_k]}"; break ;; esac; done
        fi
        def="${def:-__prep__}"
        wt --title "$(rtitle 5 'nośnik')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "Nośnik musi być podłączony. Kopia ląduje pod  <pula>/replica/<dataset źródła>.$([ -n "$busy" ] && printf '\nDyski innych replik (nie do wyboru):%s' "$busy")" "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" \
           "${items[@]}" || { step=3; continue; }
        pool="$WT_OUT"
        if [ "$pool" = __prep__ ]; then
            np="$(hostname -s 2>/dev/null || hostname)-$NAME"; np="$(printf '%s' "$np" | tr -c 'A-Za-z0-9._:\n-' '-')"
            prep_media "$np" replica || continue
            DST="$PREP_DST"; GUIDS=""; add_guid "$PREP_GUID"; step=5; continue
        fi
        if [ "$pool" = __del__ ]; then
            LE_ITEMS=(); g=""
            for g in ${GUIDS//,/ }; do LE_ITEMS+=("$g"); done
            menu=()
            for g in "${LE_ITEMS[@]}"; do
                menu+=("$g" "dysk ID $g$([ "$g" = "$(guid_of_pool "$cur")" ] && echo '  (teraz w slocie)')")
            done
            wt --title "Replika $NAME -- usuń dysk" --ok-button "Usuń" --cancel-button "Wstecz" --notags \
               --menu "Który dysk przestaje należeć do repliki? Dane na nim ZOSTAJĄ;\nwłożony później będzie odrzucony jako obcy." "$(fit $((${#menu[@]} / 2 + 4)))" "$W" "$((${#menu[@]} / 2))" \
               "${menu[@]}" || continue
            g="$WT_OUT"; GUIDS="$(printf '%s' ",$GUIDS," | sed "s/,$g,/,/; s/^,//; s/,\$//")"
            continue
        fi
        if [ "$pool" = __add__ ]; then
            # Replika sprzed zapisu ID (P5) ma pustą listę: dopisane byłoby TYLKO nowe ID,
            # a jej stary dysk zostałby odrzucony jako obcy (W11, pve9b 2026-10-11).
            if [ -z "$GUIDS" ]; then
                g="$(guid_of_pool "$cur")"
                if [ -n "$g" ]; then
                    add_guid "$g"
                else
                    wt --title "Obecny dysk nie jest zapisany" --yes-button "Dalej" --no-button "Wstecz" \
                       --yesno "Replika '$NAME' nie ma jeszcze zapisanych ID dysków, a jej obecnego dysku nie ma w maszynie.\nPo dodaniu nowego dysku stary będzie odrzucany jako obcy -- dodasz go, gdy go włożysz\n(zmiana repliki, nośnik, wybór obecnego dysku)." 11 "$W" || continue
                fi
            fi
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
        wt --title "$(rtitle 6 'kiedy kopiować?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$def" \
           --menu "$([ "$MEDIA" = removable ] && printf '%s' 'Nośnik wymienny jest podłączany tylko na czas kopii; gdy go nie ma w maszynie,\nbieg po cichu nic nie robi.' || printf '%s' 'Nośnik stały jest stale w maszynie: kopia idzie o tej porze.')$([ "$EDIT" -eq 1 ] && printf '%s' " Teraz: $([ "$SCHED" = on-insert ] && echo 'tylko po włożeniu' || echo "$SCHED")")" "$(fit $((${#items[@]} / 2 + 3)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || { step=4; continue; }
        if [ "$WT_OUT" = __other__ ]; then
            wt --title "Replika $NAME -- własny harmonogram" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Pięć pól crona (minuta godzina dzień miesiąc dzień-tygodnia):" 9 "$W" "$([ "$SCHED" = on-insert ] || echo "$SCHED")" || continue
            _c="$(printf '%s' "$WT_OUT" | tr -s ' ' | sed 's/^ //; s/ $//')"
            # Kampania 2026-10-22: "0 22 * * *zle" przechodził aż do planu. Pięć pól ze znaków crona.
            if ! printf '%s\n' "$_c" | awk '
                    { if (NF != 5) exit 1
                      n = "^(\\*|[0-9]+(-[0-9]+)?)(/[0-9]+)?(,(\\*|[0-9]+(-[0-9]+)?)(/[0-9]+)?)*$"
                      w = "^[A-Za-z][A-Za-z][A-Za-z](-[A-Za-z][A-Za-z][A-Za-z])?(,[A-Za-z][A-Za-z][A-Za-z](-[A-Za-z][A-Za-z][A-Za-z])?)*$"
                      for (i = 1; i <= 5; i++) if ($i !~ n && !(i >= 4 && $i ~ w)) exit 1 }'; then
                wt --title "Zły harmonogram" --msgbox "'$_c' -- potrzeba pięciu pól crona (minuta godzina dzień miesiąc dzień-tygodnia), np. 30 21 * * 1-5." 9 "$W"
                continue
            fi
            SCHED="$_c"
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
        if [ "$MEDIA" = removable ] && [ "$MENU" -eq 0 ]; then
            if [ "$SCHED" != on-insert ]; then
                _dn=""; [ "$ONINS" = yes ] || _dn="--defaultno"
                if wt --title "Replika $NAME -- także po włożeniu?" --yes-button "Tak" --no-button "Nie" $_dn \
                   --yesno "Uruchamiać kopię także po włożeniu dysku tej repliki?\n\nTak: włożony dysk -- kopia minutę po włożeniu (czas na wyjęcie złego dysku),\npotem dalej wg harmonogramu.\nNie: tylko wg harmonogramu. Inny dysk -- nic się nie dzieje." 12 "$W"; then ONINS=yes; else ONINS=no; fi
            fi
        fi
        trig_calc
        step=6 ;;
    6)  # plan
        ARGV=("$ZB" add-replica "$NAME" "--source=$SRCS" "--dst=$DST" "--schedule=$SCHED")
        [ "$MEDIA" = fixed ] && ARGV+=(--fixed) || ARGV+=(--removable)
        [ "$REC" = yes ] && ARGV+=(--recursive=yes) || ARGV+=(--recursive=no)
        ARGV+=(${XARGS[@]+"${XARGS[@]}"})
        [ "$PASSIVE" = yes ] && ARGV+=(--passive)
        [ -n "$KEEP" ] && ARGV+=("--keep=$KEEP")
        [ "$RAW" = yes ] && ARGV+=(--raw)
        [ "$HIST" != all ] && ARGV+=("--history=$HIST")
        if [ "$MEDIA" = removable ]; then
            [ -n "$GUIDS" ] && ARGV+=("--media-guid=$GUIDS")
            [ "$SCHED" != on-insert ] && ARGV+=("--on-insert=$ONINS")
        fi
        [ -n "$MONDAYS" ] && ARGV+=("--monitor-warn=${MONDAYS}d" "--monitor-crit=$(( (MONDAYS * 3 + 1) / 2 ))d")
        info "Replika $NAME" "Liczę plan..."
        if ! "${ARGV[@]}" --plan >"$TMPD/plan.txt" 2>&1; then
            verb_refusal "$TMPD/plan.txt" | fold -s -w $((W - 6)) >"$TMPD/why.txt"
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
            echo "Migawki:    $([ "$PASSIVE" = yes ] && echo "cała historia (istniejące, bez własnych)" || echo "stan na chwilę kopii (własne, replica_)")"
            [ "$PASSIVE" = yes ] || echo "Na dysku:   $([ -n "$KEEP" ] && echo "$KEEP ostatnich kopii, niezależnie od kolektora" || echo "odbicie kolektora")"
            [ "$RAW" = yes ] && echo "Szyfrowane: źródło jest zaszyfrowane -- kopia idzie zaszyfrowana (raw), kolektor nie potrzebuje klucza"
            # X10: przy "cała historia" i przy "N ostatnich" Historia nie jest wyborem -- plan mówi,
            # co naprawdę idzie, a nie wartość, której silnik nie użyje.
            if [ "$PASSIVE" = yes ]; then echo "Historia:   wszystkie istniejące migawki (lustro kolektora)"
            elif [ -n "$KEEP" ]; then echo "Historia:   tylko najnowsze zdjęcie replica_ (pośrednie nie trafiają)"
            else echo "Historia:   $(eng_hist_words "$HIST")"; fi
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
                        echo "Po włożeniu: kopia po odczekaniu (replica.insert_wait, domyślnie 60 s) -- krok: reguła udev ZOSTANIE $([ "$RULE_HERE" = old ] && echo ODNOWIONA || echo ZAŁOŻONA)"
                        echo "             (install-media-trigger --install; jedna na host)"
                    else
                        echo "Po włożeniu: kopia po odczekaniu (replica.insert_wait, domyślnie 60 s); reguła udev jest na hoście"
                    fi
                else
                    echo "Po włożeniu: nic -- kopia tylko wg harmonogramu"
                fi
            fi
            if [ "$UNTRIG" = yes ]; then
                echo "Reguła udev \"po włożeniu\" ZOSTANIE ZDJĘTA -- żadna replika z niej nie korzysta"
                echo "             (remove-media-trigger --install; jedna na host)"
            fi
            grep -E '^(!!!|WARNING|>>> )' "$TMPD/plan.txt" | grep -iv 'plan' | sed 's/^/  /' | head -4
            echo
            echo "Zadanie w cronie:"
            sed -n '/co sie zmieni w crontabie/,$p' "$TMPD/plan.txt" | grep -E "^\s+\+\S" | grep -F "replica" \
                | sed -E 's/^\s+\+//' | awk '{w=($1=="#on-insert")?"po włożeniu":$1" "$2" "$3" "$4" "$5; m=match($0,/zfs-job\.sh "[^"]*"/); l=m?substr($0,RSTART+12,RLENGTH-13):(/zfs-media-gate\.sh age|check-snap-age\.sh/?"monitor: wiek kopii na nośniku":"?"); print "  + " w "   " l}' | head -6
            if [ "$EDIT" -eq 1 ]; then
                echo
                echo "Źródło usunięte z listy zostawia swoją kopię na nośniku (wyczyścić dysk: Dodaj dysk = formatowanie)."
            fi
            echo
            echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--install --yes"
        } >"$TMPD/plan2.txt"
        # Enter = WYKONAJ, jak w kreatorze relacji (jedno zachowanie planów).
        if ! yesno_text "$TMPD/plan2.txt" "Replika $NAME -- plan" "WYKONAJ" "Wstecz"; then
            if [ "$ENGINE_ONLY" -eq 1 ]; then
                replica_engine && continue
                clear 2>/dev/null; echo "replica: przerwane, nic nie zmieniono"; exit 1
            fi
            step=5; continue
        fi
        : >"$TMPD/run.log"
        RC=0; run_progress "Replika $NAME: instaluję" "$TMPD/run.log" "${ARGV[@]}" --install --yes || RC=$?
        if [ "$RC" -eq 0 ] && [ "$TRIG" = yes ]; then
            run_progress "Replika $NAME: instaluję" "$TMPD/run.log" "$ZB" install-media-trigger --install || RC=$?
        fi
        if [ "$RC" -eq 0 ] && [ "${UNTRIG:-no}" = yes ]; then
            run_progress "Replika $NAME: instaluję" "$TMPD/run.log" "$ZB" remove-media-trigger --install || RC=$?
        fi
        if [ -n "${ZFS_TUI_LOG:-}" ]; then
            { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
        fi
        if [ "$RC" -eq 0 ]; then
            # U11 (właściciel 2026-10-19): pełne zdania, bez skrótu "F7 na F6".
            if [ "$SCHED" = on-insert ]; then _first="ruszy po włożeniu dysku"
            elif [ "$MEDIA" = removable ] && [ "$ONINS" = yes ]; then _first="ruszy po włożeniu dysku albo o czasie z harmonogramu"
            else _first="ruszy o czasie z harmonogramu"; fi
            { if [ "$EDIT" -eq 1 ]; then echo "GOTOWE: replika '$NAME' zmieniona (rc=$RC)."; echo "    Następna kopia $_first."
              else echo "GOTOWE: replika '$NAME' zainstalowana (rc=$RC)."; echo "    Pierwsza kopia $_first."; fi
              echo "    Żeby zrobić ją od razu: ekran Replika (klawisz F6), zaznacz '$NAME' i naciśnij F7 (Uruchom teraz)."
            } >"$TMPD/result.txt"
            result_box "Replika $NAME: GOTOWE" 0 "$TMPD/run.log" "$(cat "$TMPD/result.txt")"
        else
            echo "Nie udało się -- nic nie zainstalowano." >"$TMPD/result.txt"
            result_box "Replika $NAME: instaluję" "$RC" "$TMPD/run.log" "" "$(cat "$TMPD/result.txt")"
        fi
        exit "$RC" ;;
    esac
done
