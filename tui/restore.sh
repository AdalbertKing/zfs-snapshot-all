#!/bin/bash
# restore.sh RELACJA -- okno "Przywróć" (restore) z poziomu relacji, w whiptailu.
#
# NIE ma własnej logiki odzysku. Zbiera cztery odpowiedzi (co, z kiedy, dokąd, potwierdzenie),
# składa z nich JEDNO polecenie `zfs-backup.sh restore` i uruchamia je w terminalu. Samo
# okno "na pewno?" jest jedynym potwierdzeniem (właściciel 2026-10-29), więc polecenie
# dostaje --yes i w terminalu już nie pyta; --plan okno nie dodaje.
#
# Kroki (Wstecz cofa o jeden, na pierwszym wychodzi z okna):
#   1 Co?     drzewo (tui/tree.py) kopii relacji na tym kolektorze; domyślnie cała relacja
#   3 Z kiedy? punkt odzysku = migawka kopii (najnowsza albo wcześniejsza), pełne nazwy
#   2 Dokąd?  "obok" oryginału (--onto, nic nie nadpisuje) albo "na miejsce" (NADPISUJE)
#   4 Sprawdź  podsumowanie + polecenie; "Uruchom" odpala je
# U109 (właściciel 2026-10-28, symulacja A): najpierw Z CZEGO (co, z kiedy), potem DOKĄD --
# ta sama kolejność co z F4, gdzie migawka jest już wybrana. Numery kroków zostały (1, 3, 2, 4),
# żeby testy i komentarze dalej mówiły o tych samych krokach.
#
# restore.sh --from-copy [DATASET] -- drugi tryb "Przywróć z dysku": kopia leży na tym hoście
# (np. zaimportowana pula z dysku USB), bez relacji i bez configu. Kroki: skąd (drzewo
# wszystkich datasetów hosta; DATASET = wstępnie zaznaczony), z kiedy (+ historia), dokąd
# (nazwa na tym hoście), sprawdź. Składa `restore --from-copy=.. --onto=.. [--at=..]
# [--with-history] [--overwrite]`; podgląd i pytanie "Restore? [y/N]" robi samo polecenie.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka, ZFS_TREE =
# program drzewa (jak w basket_step), ZFS_CONF_DIR (domyślnie /etc/zfs-snapshot-all), PYTHON.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "restore: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
REL="${1:-}"
[ -n "$REL" ] || { echo "usage: restore.sh RELATION | restore.sh --from-copy [DATASET]" >&2; exit 2; }
# --dataset=DS / --snapshot=NAME (GUI F4 Kopie, 2026-10-28): kopia i migawka juz wybrane w GUI;
# okno startuje na nich i raz pomija dwa kroki, ktore pytalyby o to samo. Wartosci to dane --
# tylko znaki z listy, nigdy eval. Reszta argumentow (DATASET pozycyjny) bez zmian.
OPT_DS=""; OPT_SNAP=""; POS=()
_ARG_RE='^[A-Za-z0-9_.:/-]+$'
for _a in "${@:2}"; do
    case "$_a" in
        --dataset=*)
            OPT_DS="${_a#--dataset=}"
            [[ "$OPT_DS" =~ $_ARG_RE ]] || { echo "restore.sh: bad --dataset value '$OPT_DS' (allowed: A-Za-z0-9_.:/-)" >&2; exit 2; } ;;
        --snapshot=*)
            OPT_SNAP="${_a#--snapshot=}"
            [[ "$OPT_SNAP" =~ $_ARG_RE ]] && [ "${OPT_SNAP#*/}" = "$OPT_SNAP" ] \
                || { echo "restore.sh: bad --snapshot value '$OPT_SNAP' (allowed: A-Za-z0-9_.:- , no '/')" >&2; exit 2; } ;;
        *) POS+=("$_a") ;;
    esac
done
AUTO_DS="$OPT_DS"; AUTO_SNAP="$OPT_SNAP"      # "raz": zerowane po uzyciu
CONFDIR="${ZFS_CONF_DIR:-/etc/zfs-snapshot-all}"
WT_BACKTITLE="$(Tv 'Przywracanie z relacji $REL -- $(hostname)' '$REL' "$REL" '$(hostname)' "$(hostname)")"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

abort() { clear 2>/dev/null; wt_end_nochange "$(T 'Odzysk: przerwane, nic nie zmieniono')"; exit 1; }
join_by_comma() { local IFS=,; echo "$*"; }
# P3 (właściciel 10-15): godziny punktów są w strefie HOSTA (lab: UTC), a nie operatora --
# 20:01 na ekranie to 22:01 w Polsce latem. Strefy operatora przez SSH nie znamy; okno
# mówi, w jakiej strefie jest czas, zamiast udawać, że to jego.
TZN="$(date +%Z 2>/dev/null)"

# ---- URUCHOM: CMD (tablica) + CMDTXT (do pokazania); kończy skrypt kodem polecenia ----------
run_cmd() {
    clear 2>/dev/null
    echo "\$ $CMDTXT"; echo
    "${CMD[@]}" 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
    echo
    # Napis zwykłym echo, jak w delete-relation.sh: podpowiedź `read -p` idzie na stderr,
    # a `2>/dev/null` ją chowało -- okno czekało na Enter bez słowa (właściciel, P1 10-15).
    if [ "$RC" -eq 0 ]; then wt_end "$(T 'Odzysk: gotowe')"
    else
        # Sprawdź ponownie (właściciel 2026-10-26): odmowa przed zmianą (zajęty dataset, działający
        # gość) zwykle znika po zatrzymaniu usługi -- to samo polecenie jeszcze raz, bez wracania.
        echo "$(Tv '=== NIE WYSZŁO (rc=$RC) -- komunikat polecenia powyżej. Enter = powrót do GUI, p + Enter = sprawdź ponownie (to samo polecenie)' '$RC' "$RC")"
        local _a=""; read -r _a </dev/tty 2>/dev/null || true
        case "$_a" in p|P) run_cmd ;; esac
    fi
    exit "$RC"
}

# points.tsv (czas utworzenia <TAB> nazwa migawki, najnowsza pierwsza) -> PT_TIME + menu
# (menu p0..pN; p0 = najnowszy, kursor na nim). Wspólne dla obu trybów.
#
# PT_AT = granica --at dla punktu: "tuż przed NASTĘPNYM (nowszym) punktem", nie sekunda
# tego punktu. Jeden bieg robi migawki datasetów po kolei, sekundy po sobie (pve10, 10-15:
# home …:03, adam …:05, ewa …:07); --at = sekunda migawki korzenia odcinało dzieci tego
# samego biegu i cofało je o godzinę dalej (P7, wyłapane w podglądzie testu właściciela).
build_points() {
    local cr nm tm tier lbl prev=""
    PT_TIME=(); PT_AT=(); PT_NAME=(); menu=()
    while IFS=$'\t' read -r cr nm; do
        [ -n "$cr" ] || continue
        tm=$(date -d "@$cr" '+%Y.%m.%d %H:%M:%S')   # zapis daty GUI (RRRR.MM.DD), tylko do oczu
        if [ -n "$prev" ]; then PT_AT+=("$(date -d "@$((prev - 1))" '+%Y-%m-%d %H:%M:%S')"); else PT_AT+=(""); fi
        prev="$cr"
        # U109: pełna nazwa migawki (jak NAME w zfs list -t snapshot), nie sam szczebel --
        # "daily" nie mówiło, KTÓRA to migawka.
        # Bez dopisku "(najnowsza)": przy 80 kolumnach pelna nazwa go ucinala; najnowsza jest na
        # gorze i kursor na niej stoi (mowi o tym tekst okna).
        lbl="$tm  @$nm"
        menu+=("p${#PT_TIME[@]}" "$(clip_label "$lbl" $((W - 14)))")
        PT_TIME+=("$tm"); PT_NAME+=("$nm")
    done <"$TMPD/points.tsv"
}

# U109: podsumowanie podaje NAZWĘ wybranej migawki, nie "Punkt: najnowszy".
# snap_summary <dataset, z którego wzięto listę punktów>; idx/AT/PT z kroku "z kiedy".
snap_summary() {
    local sn="${PT_NAME[${idx:-0}]:-?}"
    if [ -n "$AT" ]; then
        echo "$(Tv 'Migawka: $SNAP ($PT, $TZN)' '$SNAP' "$1@$sn" '$PT' "$PT" '$TZN' "$TZN")"
        echo "$(Tv '         pozostałe datasety: ich ostatnia migawka do $AT' '$AT' "$(printf '%s' "$AT" | sed -E 's/^([0-9]{4})-([0-9]{2})-([0-9]{2})/\1.\2.\3/')")"
    else
        echo "$(Tv 'Migawka: $SNAP ($PT, najnowsza)' '$SNAP' "$1@$sn" '$PT' "${PT_TIME[0]:-?}")"
        echo "$(T '         pozostałe datasety: ich najnowsza migawka')"
    fi
}

# --snapshot=NAME: czy NAME jest w points.tsv? Tak -> AUTO_IDX = indeks punktu (0 = najnowszy,
# jak numer w menu p0..pN), rc 0; nie -> rc 1. Dziala na calej liscie (bez limitu 50 menu).
auto_point() {
    AUTO_IDX="$(awk -F'\t' -v n="$1" '$2 == n { print NR - 1; exit }' "$TMPD/points.tsv" | tr -d '\r')"
    [ -n "$AUTO_IDX" ]
}
# lista punktow dluzsza niz menu (po zgubionym --snapshot=): tnie do 50 i buduje menu od nowa
points_cut() {
    head -n 50 "$TMPD/points.tsv" >"$TMPD/points.cut" && mv "$TMPD/points.cut" "$TMPD/points.tsv"
    build_points
}

# ================= TRYB "PRZYWRÓĆ Z DYSKU" (--from-copy) ====================================
if [ "$REL" = --from-copy ]; then
    PRE="${POS[0]:-}"
    [ -n "$OPT_DS" ] && PRE="$OPT_DS"       # --dataset= = DATASET pozycyjny (wstepne zaznaczenie)
    WT_BACKTITLE="$(Tv 'Przywracanie z dysku -- $(hostname)' '$(hostname)' "$(hostname)")"
    # podpowiedź nazwy: kopia z kolektora (<pula>/.../backups/<host>/<ścieżka>) -> <ścieżka>;
    # inaczej <pula>/restore/<ostatni człon>
    SUG_RE='^[^/]+/(.*/)?backups/[^/]+/(.+)$'
    # Kampania 2026-10-22: z nośnika repliki (<nośnik>/replica/<pula>/...) podpowiedź padała NA
    # nośnik (gwlive/restore/archive) -- dysk, który się wyjmuje. Taka kopia wraca do swojej
    # puli: <pula>/restore/<ostatni człon>, gdy ta pula jest na tym hoście.
    REP_RE='^[^/]+/replica/([^/]+)/.+$'
    sug() {
        if [[ "$1" =~ $REP_RE ]] && zpool list -H -o name "${BASH_REMATCH[1]}" >/dev/null 2>&1; then
            printf '%s/restore/%s' "${BASH_REMATCH[1]}" "${1##*/}"
        elif [[ "$1" =~ $SUG_RE ]]; then printf '%s' "${BASH_REMATCH[2]}"
        else printf '%s/restore/%s' "${1%%/*}" "${1##*/}"; fi
    }
    pool_ok() {   # <nazwa> -> 0 gdy ma postać <pula>/<coś> i ta pula jest na tym hoście
        case "$1" in */?*) ;; *) return 1 ;; esac
        zpool list -H -o name -- "${1%%/*}" >/dev/null 2>&1
    }
    FROM=(); ANS=(); ONTO=(); EXIST=(); AT=""; HIST=0; OVERWRITE=0; CMD=()
    step=1
    while :; do
        case $step in
        1)  # ---- SKĄD? ---------------------------------------------------------------------
            zfs list -H -p -o name,used,type 2>/dev/null >"$TMPD/ds.tsv"
            if ! [ -s "$TMPD/ds.tsv" ]; then
                geom
                wt --title "$(T 'Przywróć z dysku')" \
                   --msgbox "$(T 'Na tym hoście nie widać żadnego datasetu. Podłącz dysk i zaimportuj pulę (zpool import <pula>), potem spróbuj jeszcze raz.')" 9 "$W"
                exit 1
            fi
            # --dataset= z GUI: kopia jest na liscie kandydatow -> start od kroku "z kiedy", jakby
            # operator zaznaczyl tylko ja i dal Enter. Raz: Wstecz z niego pokazuje drzewo (wstepnie zaznaczone).
            if [ -n "$AUTO_DS" ]; then
                if awk -F'\t' -v d="$AUTO_DS" '$1 == d { f = 1 } END { exit !f }' "$TMPD/ds.tsv"; then
                    FROM=("$AUTO_DS"); ANS=(); AUTO_DS=""; step=3; continue
                fi
                AUTO_DS=""
            fi
            "$PY" - "$TMPD/ds.tsv" "$TMPD/tree-spec.json" "$(T 'Przywróć z dysku: skąd?')" "$(hostname)" "$PRE" <<'PYEOF' || exit 1
import sys, json
import os as _os
_C = json.load(open(_os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if _os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
seen = set(); ds = []
for ln in open(sys.argv[1], encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) < 3 or p[0] in seen:
        continue
    seen.add(p[0])
    try:
        used = int(p[1])
    except ValueError:
        used = None
    ds.append({"name": p[0], "used": used, "type": p[2]})
roots = [sys.argv[5]] if sys.argv[5] and sys.argv[5] in seen else []
spec = {"title": sys.argv[3], "host": sys.argv[4], "show_mode": False, "no_exc": True,
        "legend": _(u" [x] odtwarzane razem z tym, co pod nim   dysku nie ma? zpool import"),
        "recursion": "flat", "hide": [], "datasets": ds, "roots": roots, "excl": {}}
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(spec, f, ensure_ascii=False)
PYEOF
            rm -f "$TMPD/tree-out.json"
            ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || abort
            [ -s "$TMPD/tree-out.json" ] || abort
            # roots.txt: zaznaczone korzenie w kolejności drzewa; stdout: BACK | OK
            FLAG=$("$PY" - "$TMPD/tree-out.json" "$TMPD/roots.txt" <<'PYEOF' | tr -d '\r'
import sys, json
o = json.load(open(sys.argv[1], encoding="utf-8"))
if o.get("action") == "back":
    print("BACK"); sys.exit(0)
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as f:
    for r in o.get("roots") or []:
        f.write("%s\n" % r)
print("OK")
PYEOF
            ) || abort
            [ "$FLAG" = OK ] || abort
            FROM=(); ANS=()
            while IFS= read -r r; do [ -n "$r" ] && FROM+=("$r"); done <"$TMPD/roots.txt"
            if [ "${#FROM[@]}" -eq 0 ]; then
                geom
                wt --title "$(T 'Przywróć z dysku')" --msgbox "$(T 'Nic nie zaznaczono.')" 7 "$W"
                continue
            fi
            step=3 ;;
        2)  # ---- DOKĄD? --------------------------------------------------------------------
            i=0; GOBACK=0
            while [ "$i" -lt "${#FROM[@]}" ]; do
                def="${ANS[$i]:-$(sug "${FROM[$i]}")}"
                txt="$(Tv 'Pod jaką nazwą odtworzyć na tym hoście:
  $SRC
(datasety pod nim przyjdą razem z nim)' '$SRC' "${FROM[$i]}")"
                geom
                if wt --title "$(Tv 'Przywróć z dysku: dokąd? ($((i + 1))/${#FROM[@]})' '$((i + 1))' "$((i + 1))" '${#FROM[@]}' "${#FROM[@]}")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
                      --inputbox "$txt" "$(fit 6)" "$W" "$def"; then
                    [ -n "$WT_OUT" ] || continue
                    # P5 (właściciel 10-15): nazwa bez puli ("restore/home") przechodziła
                    # i dopiero polecenie odmawiało. Pula musi istnieć NA TYM hoście.
                    if ! pool_ok "$WT_OUT"; then
                        ANS[$i]="$WT_OUT"
                        geom
                        wt --title "$(T 'Przywróć z dysku: zła nazwa')" \
                           --msgbox "$(Tv ''\''$WT_OUT'\'' nie zaczyna się od puli tego hosta.' '$WT_OUT' "$WT_OUT")

$(Tv 'Nazwa ma mieć postać <pula>/<ścieżka>, np. $SUG.' '$SUG' "$(sug "${FROM[$i]}")")
$(Tv 'Pule tutaj: $POOLS' '$POOLS' "$(zpool list -H -o name 2>/dev/null | tr '\n' ' ')")" 11 "$W"
                        continue
                    fi
                    ANS[$i]="$WT_OUT"; i=$((i + 1))
                else
                    [ "$i" -eq 0 ] && { GOBACK=1; break; }
                    i=$((i - 1))
                fi
            done
            [ "$GOBACK" -eq 1 ] && { step=3; continue; }
            ONTO=("${ANS[@]}")
            DUP=""
            for ((i = 0; i < ${#ONTO[@]}; i++)); do
                for ((j = i + 1; j < ${#ONTO[@]}; j++)); do
                    [ "${ONTO[$i]}" = "${ONTO[$j]}" ] && DUP="${ONTO[$i]}"
                done
            done
            if [ -n "$DUP" ]; then
                geom
                wt --title "$(T 'Przywróć z dysku')" --msgbox "$(Tv 'Dwa źródła mają ten sam cel ($DUP) -- podaj różne nazwy.' '$DUP' "$DUP")" 8 "$W"
                continue
            fi
            EXIST=()
            for o in "${ONTO[@]}"; do zfs list -H -o name -- "$o" >/dev/null 2>&1 && EXIST+=("$o"); done
            OVERWRITE=0
            if [ "${#EXIST[@]}" -gt 0 ]; then
                txt="$(T 'Te cele JUŻ ISTNIEJĄ na tym hoście:')"
                for o in "${EXIST[@]}"; do txt+=$'\n'"  $o"; done
                txt+=$'\n\n'"$(T 'Nadpisać je (--overwrite)? To, co tam jest, zostanie zastąpione kopią z dysku.')"
                geom
                wt --title "$(T 'Przywróć z dysku: cel istnieje')" --yes-button "$(T Nadpisz)" --no-button "$(T Wstecz)" --defaultno \
                   --yesno "$txt" "$(fit $((${#EXIST[@]} + 5)))" "$W" || continue
                OVERWRITE=1
            fi
            step=4 ;;
        3)  # ---- Z KIEDY? ------------------------------------------------------------------
            # punkty: migawki pierwszego źródła; najnowsza pierwsza, max 50
            # --snapshot= z GUI: szukamy na calej liscie, nie tylko w 50 pozycjach menu
            LIM=50; [ -n "$AUTO_SNAP" ] && LIM=100000
            zfs list -H -p -t snapshot -o name,creation -s creation -d 1 -- "${FROM[0]}" 2>/dev/null \
                | tr -d '\r' | awk -F'\t' '{ n = $1; sub(/^[^@]*@/, "", n); print $2 "\t" n }' | tac | head -n "$LIM" >"$TMPD/points.tsv"
            geom
            build_points
            if [ "${#PT_TIME[@]}" -eq 0 ]; then
                wt --title "$(T 'Przywróć z dysku')" --msgbox "$(Tv '${FROM[0]} nie ma żadnej migawki -- nie ma z czego odtworzyć.' '${FROM[0]}' "${FROM[0]}")" 8 "$W"
                exit 1
            fi
            # Raz: menu pomijane tylko przy pierwszym wejsciu; po Wstecz pokazuje sie normalnie.
            SKIPMENU=0
            if [ -n "$AUTO_SNAP" ]; then
                if auto_point "$AUTO_SNAP"; then
                    SKIPMENU=1
                else
                    wt --title "$(T 'Przywróć z dysku')" --msgbox "$(Tv 'Migawki $SNAPN nie ma w $SNAPDS -- wybierz z listy.' '$SNAPN' "$AUTO_SNAP" '$SNAPDS' "${FROM[0]}")" 8 "$W"
                    points_cut
                fi
                AUTO_SNAP=""
            fi
            if [ "$SKIPMENU" -eq 1 ]; then
                WT_OUT="p$AUTO_IDX"
            else
                wt --title "$(T 'Przywróć z dysku: z kiedy?')" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags \
                   --default-item "p$(( ${idx:-0} < ${#PT_TIME[@]} ? ${idx:-0} : 0 ))" --menu "$(Tv 'Migawki $DS (zfs list -t snapshot), najnowsza na górze.' '$DS' "${FROM[0]}")" \
                   "$(fit $((${#PT_TIME[@]} + 3)))" "$W" "$(lhfit ${#PT_TIME[@]} 3)" "${menu[@]}" || { step=1; continue; }
            fi
            idx="${WT_OUT#p}"
            if [ "$idx" = 0 ]; then AT=""; PT=""; else AT="${PT_AT[$idx]}"; PT="${PT_TIME[$idx]}"; fi
            geom
            wt --title "$(T 'Przywróć z dysku: historia')" --yes-button "$(T Tak)" --no-button "$(T Nie)" --defaultno \
               --yesno "$(Tv 'Migawka: $SNAP\n\nPrzenieść też wszystkie starsze migawki (z historią)?\nNie = tylko ta migawka.' '$SNAP' "${FROM[0]}@${PT_NAME[$idx]:-?}")" "$(fit 5)" "$W"
            hrc=$?
            case $hrc in
                0) HIST=1 ;;
                1) HIST=0 ;;
                *) continue ;;           # Esc itp. -> znów lista punktów
            esac
            step=2 ;;
        4)  # ---- SPRAWDŹ + POLECENIE -------------------------------------------------------
            CMD=("$ZB" restore "--from-copy=$(join_by_comma "${FROM[@]}")" "--onto=$(join_by_comma "${ONTO[@]}")")
            [ -n "$AT" ] && CMD+=("--at=$AT")
            [ "$HIST" -eq 1 ] && CMD+=("--with-history")
            [ "$OVERWRITE" -eq 1 ] && CMD+=("--overwrite")
            CMD+=("--yes")      # to okno jest jedynym "Na pewno?" (wlasciciel 2026-10-29)
            CMDTXT=""
            for w in "${CMD[@]}"; do CMDTXT+="${CMDTXT:+ }$(shq "$w")"; done
            {
                echo "$(T 'Skąd:   dysk / inny dataset na tym hoście')"
                echo "$(T 'Co -> dokąd:')"
                for ((i = 0; i < ${#FROM[@]}; i++)); do
                    echo "  ${FROM[$i]} -> ${ONTO[$i]}"
                    for o in ${EXIST[@]+"${EXIST[@]}"}; do [ "$o" = "${ONTO[$i]}" ] && { echo "  $(T '(NADPISUJE)')"; break; }; done
                done
                snap_summary "${FROM[0]}"
                if [ "$HIST" -eq 1 ]; then echo "$(T 'Historia: tak')"; else echo "$(T 'Historia: nie')"; fi
                echo
                echo "$(T 'Polecenie:')"
                echo "  $CMDTXT"
                echo
                echo "$(T '<Wykonaj> uruchamia to od razu, bez dalszych pytań; zaszyfrowana kopia -- zapyta tylko o klucz albo plik klucza.')"
            } >"$TMPD/summary.txt"
            yesno_text "$TMPD/summary.txt" "$(T 'Przywróć z dysku: na pewno?')" "$(T Wykonaj)" "$(T Wstecz)" --defaultno || { step=2; continue; }
            run_cmd ;;
        esac
    done
fi

# ---- KROK 0: który config trzyma kopie tej relacji + jej punkty odzysku --------------------
geom
info "$(Tv 'Przywróć $REL' '$REL' "$REL")" "$(T 'Czytam kopie i punkty odzysku...')"
CFG=""
for C in "$CONFDIR"/jobs.*.conf; do
    [ -f "$C" ] || continue
    "$ZB" restore --plan "$REL" --config="$C" --json >"$TMPD/plan.json" 2>/dev/null || continue
    # rows.tsv: kopia <TAB> źródło -- tylko wiersze, których kopia istnieje
    "$PY" - "$TMPD/plan.json" <<'PYEOF' 2>/dev/null | tr -d '\r' >"$TMPD/rows.tsv"
import sys, json
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    d = {}
for r in d.get("datasets") or []:
    if r.get("copy_exists") is True and r.get("copy"):
        print("%s\t%s" % (r["copy"], r.get("source") or ""))
PYEOF
    [ -s "$TMPD/rows.tsv" ] && { CFG="$C"; break; }
done
if [ -z "$CFG" ]; then
    geom
    wt --title "$(Tv 'Nie ma kopii relacji $REL' '$REL' "$REL")" \
       --msgbox "$(Tv 'Na tym hoście nie ma kopii relacji $REL -- przywracać można tylko na kolektorze, który ją trzyma.' '$REL' "$REL")" 8 "$W"
    exit 1
fi

ROWC=(); ROWS=()
while IFS=$'\t' read -r c s; do [ -n "$c" ] && { ROWC+=("$c"); ROWS+=("$s"); }; done <"$TMPD/rows.tsv"
case "${ROWS[0]}" in
    *:*) h="${ROWS[0]%%:*}"; TARGET="${h#*@}" ;;
    *)   TARGET="ten host" ;;
esac
# TARGET = "ten host" jest tokenem porownywanym w kodzie; na ekranie idzie TARGET_DISP.
if [ "$TARGET" = "ten host" ]; then TARGET_DISP="$(T 'ten host')"; else TARGET_DISP="$(host_name "$TARGET" "$REL")"; fi

SEL=(); ORIG=(); ONTO=(); WHOLE=0; DEST=""; BASE=""; AT=""; CMD=()
# Etykieta, pod którą cel zna ten kolektor -- to ją przyjmuje deploy.sh --allow-restore=
# (pve9b zna pve9 jako "pve9"). Gdy cel odpowie na pytanie o zgodę, bierzemy JEGO nazwę.
GRANT_LABEL="$(hostname -s 2>/dev/null || hostname)"

# ---- ZGODA ŹRÓDŁA, ZANIM CO/DOKĄD/Z KIEDY (U14, właściciel 2026-10-19) -----------------------
# Odzysk na $TARGET -- na miejsce i obok -- wymaga zgody, którą $TARGET wydaje sam
# (deploy.sh --allow-restore). Wcześniej odmowę mówiło dopiero polecenie, po angielsku,
# po przejściu wszystkich kroków. Teraz pytanie idzie od razu (`restore NAZWA --grant`,
# tylko odczyt), a bez zgody okno proponuje odzysk na TYM hoście (kopia -> nowy dataset).
GRANT=""; GRANT_RC=0
if [ "$TARGET" != "ten host" ]; then
    info "$(Tv 'Przywróć $REL' '$REL' "$REL")" "$(Tv 'Pytam $TARGET o zgodę na odzysk...' '$TARGET' "$TARGET")"
    "$ZB" restore "$REL" --grant --config="$CFG" >"$TMPD/grant.txt" 2>/dev/null; GRANT_RC=$?
    GRANT="$(sed -n 's/^GRANT=//p' "$TMPD/grant.txt" | head -1)"
    _gl="$(sed -n 's/^LABEL=//p' "$TMPD/grant.txt" | head -1)"
    [ -n "$_gl" ] && GRANT_LABEL="$_gl"
    # Brak zgody = kod != 0 ALBO odpowiedź none/unreachable/pusta -- nie ufamy samemu kodowi.
    case "$GRANT" in ""|none|unreachable) [ "$GRANT_RC" -ne 0 ] || GRANT_RC=1 ;; esac
    if [ "$GRANT_RC" -ne 0 ]; then
        if [ "$GRANT" = none ]; then
            why="$(Tv '$TARGET nie wydał temu kolektorowi zgody na odzysk.' '$TARGET' "$TARGET")"
        else
            why="$(Tv '$TARGET nie odpowiedział na pytanie o zgodę (brak połączenia albo pakietu).' '$TARGET' "$TARGET")"
        fi
        txt="$(Tv '$why Odzysk na $TARGET -- na miejsce i obok -- zostanie odrzucony.' '$why' "$why" '$TARGET' "$TARGET")

$(Tv 'Żeby go umożliwić, na $TARGET jako root:' '$TARGET' "$TARGET")
  deploy.sh --allow-restore=$GRANT_LABEL
  $(T '(na miejsce, gdy trzeba nadpisać: z --replace)')

$(T 'Bez zgody źródła: odtwórz kopię na TYM hoście jako nowy dataset albo przejrzyj jej pliki (F4 Kopie, F7 Przeglądaj).')"
        geom
        wt --title "$(Tv 'Przywróć $REL: brak zgody na $TARGET' '$REL' "$REL" '$TARGET' "$TARGET")" --ok-button "$(T Wybierz)" --cancel-button "$(T Wyjdź)" --notags \
           --menu "$txt" "$(fit 13)" "$W" 2 \
           tutaj "$(T 'Odtwórz kopię na tym hoście (bez zgody źródła)')" \
           dalej "$(T 'Mimo to dalej -- zgodę wydam przed uruchomieniem')" || abort
        if [ "$WT_OUT" = tutaj ]; then
            # kopia i migawka wybrane w GUI jadą dalej -- tryb z kopii też startuje od nich
            _fa=(--from-copy "${ROWC[0]}")
            [ -n "$OPT_DS" ] && _fa+=("--dataset=$OPT_DS")
            [ -n "$OPT_SNAP" ] && _fa+=("--snapshot=$OPT_SNAP")
            rm -rf "$TMPD"
            exec bash "$HERE/tui/restore.sh" "${_fa[@]}"
        fi
    fi
fi

step=1
while :; do
    case $step in
    1)  # ---- CO? -------------------------------------------------------------------------
        : >"$TMPD/ds.tsv"
        for c in "${ROWC[@]}"; do zfs list -H -p -o name,used,type -r "$c" 2>/dev/null >>"$TMPD/ds.tsv"; done
        # Kampania wariantów 2026-10-22 (W5): Wstecz z "Gdzie odtworzyć?" wracało do drzewa
        # z zaznaczonym WSZYSTKIM -- wybór admina znikał, a nieuważny Enter + "na miejsce"
        # nadpisałby całą relację. Drzewo dostaje z powrotem ostatni wybór.
        # SYSTEM HOSTA DOMYŚLNIE ODZNACZONY (właściciel 2026-10-26, pve2: "cała relacja" cofnęła
        # rpool/ROOT/pve-1 pod działającym hostem). Kopia, której źródło leży w <pula>/ROOT/,
        # startuje bez kratki; wybrana sama odtwarza się jako nowe środowisko startowe.
        SYSROOTS=""
        for i in "${!ROWC[@]}"; do case "${ROWS[$i]#*:}" in */ROOT/*) SYSROOTS="$SYSROOTS ${ROWC[$i]}" ;; esac; done
        SYSROOTS="$SYSROOTS" RESTORE_LAST_TREE="$TMPD/tree-last.json" "$PY" - "$TMPD/ds.tsv" "$TMPD/tree-spec.json" "$(Tv 'Przywróć $REL: co?' '$REL' "$REL")" "$TARGET" "${ROWC[@]}" <<'PYEOF' || exit 1
import sys, json, os
_C = json.load(open(os.environ["ZFS_TUI_CAT"], encoding="utf-8")) if os.environ.get("ZFS_TUI_CAT") else {}
def _(s): return _C.get(s, s)
seen = set(); ds = []
for ln in open(sys.argv[1], encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) < 3 or p[0] in seen:
        continue
    seen.add(p[0])
    try:
        used = int(p[1])
    except ValueError:
        used = None
    ds.append({"name": p[0], "used": used, "type": p[2]})
spec = {"title": sys.argv[3], "host": sys.argv[4], "show_mode": False, "no_exc": False,
        "no_close": True,      # odzysk: dwa stany Spacji, "bez przyszłych" nic tu nie znaczy
        "legend": _(u" [x] odtwarzane   [-] część   [ ] nie"),
        "recursion": "flat", "hide": [], "datasets": ds, "excl": {},
        "roots": [r for r in sys.argv[5:] if r not in (os.environ.get("SYSROOTS") or "").split()]}
if (os.environ.get("SYSROOTS") or "").split():
    spec["legend"] += u"\n" + _(u" System hosta (…/ROOT/…) domyślnie odznaczony: wybrany sam odtwarza się jako nowe środowisko startowe.")
lp = os.environ.get("RESTORE_LAST_TREE") or ""
if lp and os.path.exists(lp):
    try:
        last = json.load(open(lp, encoding="utf-8"))
        if last.get("roots"):
            spec["roots"] = last["roots"]; spec["excl"] = last.get("excl") or {}
    except Exception:
        pass
with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(spec, f, ensure_ascii=False)
PYEOF
        if ! grep -q '"name"' "$TMPD/tree-spec.json" 2>/dev/null || ! [ -s "$TMPD/ds.tsv" ]; then
            geom
            wt --title "$(Tv 'Przywróć $REL' '$REL' "$REL")" --msgbox "$(Tv 'Nie mogę odczytać datasetów kopii relacji $REL (zfs list nic nie zwrócił).' '$REL' "$REL")" 8 "$W"
            exit 1
        fi
        rm -f "$TMPD/tree-out.json"
        # --dataset= z GUI: kopia z tej relacji -> bez drzewa, jakby operator zaznaczyl tylko ja i dal
        # Enter (ta sama dalsza droga: sel.tsv). Raz: Wstecz z kroku 2 pokazuje drzewo z nia zaznaczona
        # (tree-last.json). Kopia spoza relacji jest ignorowana.
        _auto=0
        if [ -n "$AUTO_DS" ]; then
            for c in "${ROWC[@]}"; do [ "$c" = "$AUTO_DS" ] && _auto=1; done
            [ "$_auto" -eq 1 ] && printf '{"action":"next","roots":["%s"],"excl":{},"recursion":"flat"}\n' "$AUTO_DS" >"$TMPD/tree-out.json"
            AUTO_DS=""
        fi
        if [ "$_auto" -eq 0 ]; then
            ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || abort
        fi
        [ -s "$TMPD/tree-out.json" ] || abort
        # sel.tsv: dataset <TAB> ORIG (ścieżka u źródła); stdout: BACK | 0 | 1 (1 = cała relacja)
        FLAG=$("$PY" - "$TMPD/tree-out.json" "$TMPD/ds.tsv" "$TMPD/rows.tsv" "$TMPD/sel.tsv" <<'PYEOF' | tr -d '\r'
import sys, json
def under(n, r):
    return n == r or n.startswith(r + "/")
def srcpath(s):
    return s.split(":", 1)[1] if ":" in s else s
o = json.load(open(sys.argv[1], encoding="utf-8"))
if o.get("action") == "back":
    print("BACK"); sys.exit(0)
names = []
for ln in open(sys.argv[2], encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) >= 3 and p[0] not in names:
        names.append(p[0])
rows = []
for ln in open(sys.argv[3], encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) >= 2:
        rows.append((p[0], p[1]))
excl = o.get("excl") or {}
sel = []
for n in names:
    for r in o.get("roots") or []:
        if under(n, r) and not any(under(n, x) for x in excl.get(r) or []):
            sel.append(n); break
with open(sys.argv[4], "w", encoding="utf-8", newline="\n") as f:
    for d in sel:
        c, s = max(((c, s) for c, s in rows if under(d, c)), key=lambda t: len(t[0]))
        f.write("%s\t%s\n" % (d, srcpath(s) + d[len(c):]))
print(1 if sel and set(sel) == set(names) else 0)
PYEOF
        ) || abort
        case "$FLAG" in 0|1) ;; *) abort ;; esac      # BACK z drzewa albo błąd odczytu
        cp "$TMPD/tree-out.json" "$TMPD/tree-last.json" 2>/dev/null || :
        WHOLE="$FLAG"
        SEL=(); ORIG=()
        while IFS=$'\t' read -r d o; do [ -n "$d" ] && { SEL+=("$d"); ORIG+=("$o"); }; done <"$TMPD/sel.tsv"
        if [ "${#SEL[@]}" -eq 0 ]; then
            geom
            wt --title "$(Tv 'Przywróć $REL' '$REL' "$REL")" --msgbox "$(T 'Nic nie zaznaczono.')" 7 "$W"
            continue
        fi
        step=3 ;;
    2)  # ---- DOKĄD? ----------------------------------------------------------------------
        geom
        # System hosta (źródło w <pula>/ROOT/) wybrany sam: zamiast "na miejsce" -- nowe środowisko
        # startowe (właściciel 2026-10-26). W miejscu, pod działającym systemem: tylko z linii poleceń.
        _sys=1; for o in "${ORIG[@]}"; do case "${o#*:}" in */ROOT/*) ;; *) _sys=0 ;; esac; done
        [ "${#ORIG[@]}" -gt 0 ] || _sys=0
        if [ "$_sys" = 1 ]; then
            _m2=(srodowisko "$(Tv 'Jako nowe środowisko startowe na $TARGET -- działa po restarcie, obecny system zostaje obok' '$TARGET' "$TARGET_DISP")")
        else
            _m2=(miejsce "$(Tv 'Na miejsce na $TARGET -- NADPISUJE obecne dane' '$TARGET' "$TARGET_DISP")")
        fi
        wt --title "$(Tv 'Przywróć $REL: dokąd?' '$REL' "$REL")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags \
           --default-item obok --menu "$(T 'Gdzie odtworzyć wybrane datasety?')" "$(fit 5)" "$W" "$(lhfit 2 1)" \
           obok "$(Tv 'Obok oryginału na $TARGET -- nic nie nadpisuje' '$TARGET' "$TARGET_DISP")" \
           "${_m2[@]}" || { step=3; continue; }
        DEST="$WT_OUT"
        ONTO=()
        if [ "$DEST" = obok ]; then
            BASE="${ORIG[0]%%/*}/restore"
            txt="$(Tv 'Katalog na $TARGET, pod którym lądują odtworzone datasety (każdy pod swoją nazwą). Musi leżeć w <pula>/restore -- tylko tam zgoda na odzysk pozwala kolektorowi tworzyć.' '$TARGET' "$TARGET_DISP")"
            while :; do
                geom
                wt --title "$(Tv 'Przywróć $REL: obok -- gdzie?' '$REL' "$REL")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" \
                   --inputbox "$txt" "$(fit $((${#txt} / (W - 8) + 3)))" "$W" "$BASE" || { BASE=""; break; }
                # P5: bez "<pula>/" polecenie odmówi dopiero na celu; tu sprawdzamy postać
                # (pula leży na $TARGET, więc jej istnienia stąd nie widać).
                case "$WT_OUT" in
                    */?*) BASE="$WT_OUT"; break ;;
                    "") ;;
                    *) BASE="$WT_OUT"; geom
                       wt --title "$(Tv 'Przywróć $REL: zła nazwa' '$REL' "$REL")" --msgbox "$(Tv ''\''$WT_OUT'\'' nie ma postaci <pula>/<katalog>, np. ${ORIG[0]%%/*}/restore.' '$WT_OUT' "$WT_OUT" '${ORIG[0]%%/*}' "${ORIG[0]%%/*}")" 8 "$W" ;;
                esac
            done
            [ -n "$BASE" ] || continue            # Wstecz z pola -> znów wybór "dokąd"
            # onto.txt: ONTO(D) w kolejności SEL; kod 3 = dwa korzenie o tej samej nazwie (nazwa na stdout)
            DUP=$("$PY" - "$TMPD/sel.tsv" "$BASE" "$TMPD/onto.txt" <<'PYEOF' | tr -d '\r'
import sys
rows = []
for ln in open(sys.argv[1], encoding="utf-8"):
    p = ln.rstrip("\r\n").split("\t")
    if len(p) >= 2:
        rows.append((p[0], p[1]))
have = set(d for d, _ in rows)
tops = [(d, o) for d, o in rows if d.rsplit("/", 1)[0] not in have or "/" not in d]
base = sys.argv[2]
seen = {}
for d, o in tops:
    b = o.rsplit("/", 1)[-1]
    if b in seen:
        print(b); sys.exit(0)
    seen[b] = 1
out = []
for d, o in rows:
    t, to = max(((t, to) for t, to in tops if d == t or d.startswith(t + "/")), key=lambda x: len(x[0]))
    out.append(base + "/" + to.rsplit("/", 1)[-1] + o[len(to):])
with open(sys.argv[3], "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(out) + "\n")
PYEOF
            ) || abort
            if [ -n "$DUP" ]; then
                geom
                wt --title "$(Tv 'Przywróć $REL' '$REL' "$REL")" --msgbox "$(Tv 'Dwa wybrane datasety mają tę samą nazwę ($DUP) -- obok nie zmieszczą się pod jednym katalogiem. Wybierz je osobno.' '$DUP' "$DUP")" 9 "$W"
                step=1; continue
            fi
            while IFS= read -r o; do [ -n "$o" ] && ONTO+=("$o"); done <"$TMPD/onto.txt"
        fi
        step=4 ;;
    3)  # ---- Z KIEDY? --------------------------------------------------------------------
        # punkty: migawki wiersza, w którym leży pierwszy wybrany dataset; najnowsza pierwsza, max 50
        # --snapshot= z GUI: szukamy na calej liscie, nie tylko w 50 pozycjach menu (PT_LIM)
        PT_LIM=50; [ -n "$AUTO_SNAP" ] && PT_LIM=100000
        PT_LIM="$PT_LIM" "$PY" - "$TMPD/plan.json" "${SEL[0]}" <<'PYEOF' 2>/dev/null | tr -d '\r' >"$TMPD/points.tsv"
import sys, json, os
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = sys.argv[2]
best = None
for r in d.get("datasets") or []:
    c = r.get("copy") or ""
    if c and (s == c or s.startswith(c + "/")) and (best is None or len(c) > len(best.get("copy"))):
        best = r
for sn in list(reversed((best or {}).get("snapshots") or []))[:int(os.environ.get("PT_LIM") or 50)]:
    print("%s\t%s" % (sn.get("creation"), sn.get("name")))
PYEOF
        build_points
        if [ "${#PT_TIME[@]}" -eq 0 ]; then
            geom
            wt --title "$(Tv 'Przywróć $REL' '$REL' "$REL")" --msgbox "$(T 'Kopia nie ma żadnego punktu odzysku.')" 7 "$W"
            exit 1
        fi
        geom
        # Raz: menu pomijane tylko przy pierwszym wejsciu; po Wstecz pokazuje sie normalnie.
        SKIPMENU=0
        if [ -n "$AUTO_SNAP" ]; then
            if auto_point "$AUTO_SNAP"; then
                SKIPMENU=1
            else
                wt --title "$(Tv 'Przywróć $REL' '$REL' "$REL")" --msgbox "$(Tv 'Migawki $SNAPN nie ma w $SNAPDS -- wybierz z listy.' '$SNAPN' "$AUTO_SNAP" '$SNAPDS' "${SEL[0]}")" 8 "$W"
                points_cut
            fi
            AUTO_SNAP=""
        fi
        if [ "$SKIPMENU" -eq 1 ]; then
            WT_OUT="p$AUTO_IDX"
        else
            wt --title "$(Tv 'Przywróć $REL: z kiedy?' '$REL' "$REL")" --ok-button "$(T Dalej)" --cancel-button "$(T Wstecz)" --notags \
               --default-item "p$(( ${idx:-0} < ${#PT_TIME[@]} ? ${idx:-0} : 0 ))" --menu "$(Tv 'Migawki kopii $DS, najnowsza na górze (czas utworzenia, strefa tego hosta: $TZN). Datasety potomne dostają swoją ostatnią migawkę z tej chwili lub wcześniejszą.' '$DS' "${SEL[0]}" '$TZN' "$TZN")" \
               "$(fit $((${#PT_TIME[@]} + 3)))" "$W" "$(lhfit ${#PT_TIME[@]} 3)" "${menu[@]}" || { step=1; continue; }
        fi
        idx="${WT_OUT#p}"
        if [ "$idx" = 0 ]; then AT=""; PT=""; else AT="${PT_AT[$idx]}"; PT="${PT_TIME[$idx]}"; fi
        step=2 ;;
    4)  # ---- SPRAWDŹ + POLECENIE ---------------------------------------------------------
        CMD=("$ZB" restore "$REL")
        if [ "$DEST" = obok ]; then
            CMD+=("$REL" "--source=$(join_by_comma "${SEL[@]}")" "--onto=$(join_by_comma "${ONTO[@]}")")
        elif [ "$WHOLE" != 1 ]; then
            CMD+=("--source=$(join_by_comma "${SEL[@]}")")
            [ "$DEST" = srodowisko ] && CMD+=("--as-boot-env")
        fi
        [ -n "$AT" ] && CMD+=("--at=$AT")
        CMD+=("--config=$CFG" "--yes")   # to okno jest jedynym "Na pewno?" (wlasciciel 2026-10-29)
        CMDTXT=""
        for w in "${CMD[@]}"; do CMDTXT+="${CMDTXT:+ }$(shq "$w")"; done
        {
            echo "$(Tv 'Skąd:   relacja $REL (kopie na tym kolektorze)' '$REL' "$REL")"
            if [ "$WHOLE" = 1 ]; then echo "$(T 'Co:     cała relacja')"; else echo "$(Tv 'Co:     ${#SEL[@]} dataset(ów)' '${#SEL[@]}' "${#SEL[@]}")"; fi
            for o in "${ORIG[@]}"; do echo "          $o"; done
            if [ "$DEST" = obok ]; then
                echo "$(Tv 'Dokąd:  obok, na $TARGET:' '$TARGET' "$TARGET_DISP")"
                for o in "${ONTO[@]}"; do echo "          $o"; done
            else
                echo "$(Tv 'Dokąd:  NA MIEJSCE na $TARGET -- NADPISUJE' '$TARGET' "$TARGET_DISP")"
            fi
            snap_summary "${SEL[0]}"
            echo
            echo "$(T 'Polecenie:')"
            echo "  $CMDTXT"
            echo
            if [ "$TARGET" = "ten host" ]; then
                # relacja lokalna: zrodlo, kopia i cel na tym hoscie -- restore nie pyta o zgode
                echo "$(T 'Relacja lokalna: kopia i cel są na tym hoście, zgoda nie jest potrzebna.')"
            elif [ "$GRANT_RC" -eq 0 ] && [ -n "$GRANT" ]; then
                echo "$(Tv 'Zgoda $TARGET: $GRANT  (create = obok, rewind = na miejsce ze wspólnym punktem, replace = nadpisanie bez niego)' '$TARGET' "$TARGET" '$GRANT' "$GRANT")"
            elif [ "$DEST" = obok ]; then
                echo "$(Tv 'Wymaga zgody na $TARGET: deploy.sh --allow-restore=$GRANT_LABEL' '$TARGET' "$TARGET" '$GRANT_LABEL' "$GRANT_LABEL")"
            else
                echo "$(Tv 'Wymaga zgody na $TARGET: deploy.sh --allow-restore=$GRANT_LABEL (z --replace, gdy nie ma wspólnego punktu).' '$TARGET' "$TARGET" '$GRANT_LABEL' "$GRANT_LABEL")"
            fi
            [ "$TARGET" = "ten host" ] || echo "$(Tv '($GRANT_LABEL = nazwa tego kolektora na $TARGET; lista: ls /var/lib/zfs-snapshot-all/relationships)' '$GRANT_LABEL' "$GRANT_LABEL" '$TARGET' "$TARGET")"
            echo "$(T '<Wykonaj> uruchamia to od razu, bez dalszych pytań.')"
            [ "$DEST" = srodowisko ] && echo "$(T 'Przywrócenie w miejscu, pod działającym systemem: tylko z linii poleceń (zfs-backup.sh restore ... --in-place-live-root).')"
        } >"$TMPD/summary.txt"
        yesno_text "$TMPD/summary.txt" "$(Tv 'Przywróć $REL: na pewno?' '$REL' "$REL")" "$(T Wykonaj)" "$(T Wstecz)" --defaultno || { step=2; continue; }
        run_cmd ;;
    esac
done
