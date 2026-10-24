#!/bin/bash
# restore.sh RELACJA -- okno "Przywróć" (restore) z poziomu relacji, w whiptailu.
#
# NIE ma własnej logiki odzysku. Zbiera cztery odpowiedzi (co, dokąd, z kiedy, potwierdzenie),
# składa z nich JEDNO polecenie `zfs-backup.sh restore` i uruchamia je w terminalu. Samo
# polecenie pokazuje swój plan i samo pyta "t/n", zanim cokolwiek nadpisze -- okno nigdy
# nie dodaje --yes ani --plan.
#
# Kroki (Wstecz cofa o jeden, na pierwszym wychodzi z okna):
#   1 Co?     drzewo (tui/tree.py) kopii relacji na tym kolektorze; domyślnie cała relacja
#   2 Dokąd?  "obok" oryginału (--onto, nic nie nadpisuje) albo "na miejsce" (NADPISUJE)
#   3 Z kiedy? punkt odzysku = migawka kopii (najnowszy albo wcześniejszy)
#   4 Sprawdź  podsumowanie + polecenie; "Uruchom" odpala je
#
# restore.sh --from-copy [DATASET] -- drugi tryb "Przywróć z dysku": kopia leży na tym hoście
# (np. zaimportowana pula z dysku USB), bez relacji i bez configu. Kroki: skąd (drzewo
# wszystkich datasetów hosta; DATASET = wstępnie zaznaczony), dokąd (nazwa na tym hoście),
# z kiedy (+ historia), sprawdź. Składa `restore --from-copy=.. --onto=.. [--at=..]
# [--with-history] [--overwrite]`; podgląd i pytanie "Odtworzyc? [t/N]" robi samo polecenie.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka, ZFS_TREE =
# program drzewa (jak w basket_step), ZFS_CONF_DIR (domyślnie /etc/zfs-snapshot-all), PYTHON.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "restore: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
REL="${1:-}"
[ -n "$REL" ] || { echo "użycie: restore.sh RELACJA | restore.sh --from-copy [DATASET]" >&2; exit 2; }
CONFDIR="${ZFS_CONF_DIR:-/etc/zfs-snapshot-all}"
WT_BACKTITLE="Przywracanie z relacji $REL -- $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

abort() { clear 2>/dev/null; wt_end "Odzysk: przerwane, nic nie zmieniono"; exit 1; }
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
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE (rc=0). Enter = powrót do GUI"
    else echo "=== NIE WYSZŁO (rc=$RC) -- komunikat polecenia powyżej. Enter = powrót do GUI"; fi
    read -r _ </dev/tty 2>/dev/null || true
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
    PT_TIME=(); PT_AT=(); menu=()
    while IFS=$'\t' read -r cr nm; do
        [ -n "$cr" ] || continue
        tm=$(date -d "@$cr" '+%Y-%m-%d %H:%M:%S')
        if [ -n "$prev" ]; then PT_AT+=("$(date -d "@$((prev - 1))" '+%Y-%m-%d %H:%M:%S')"); else PT_AT+=(""); fi
        prev="$cr"
        case "$nm" in *_*) tier="${nm#*_}"; tier="${tier%%_*}" ;; *) tier="$nm" ;; esac
        # Kampania 2026-10-22: migawka bez rodziny w nazwie (2026-10-22_08-18-21) dawała
        # etykietę "08-18-21" -- ułomek godziny. Wtedy pełna nazwa migawki.
        case "$tier" in ''|*[!a-z]*) tier="$nm" ;; esac
        lbl="$tm  $tier"
        [ "${#PT_TIME[@]}" -eq 0 ] && lbl="$lbl  (najnowszy)"
        menu+=("p${#PT_TIME[@]}" "$(clip_label "$lbl" $((W - 14)))")
        PT_TIME+=("$tm")
    done <"$TMPD/points.tsv"
}

# ================= TRYB "PRZYWRÓĆ Z DYSKU" (--from-copy) ====================================
if [ "$REL" = --from-copy ]; then
    PRE="${2:-}"
    WT_BACKTITLE="Przywracanie z dysku -- $(hostname)"
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
                wt --title "Przywróć z dysku" \
                   --msgbox "Na tym hoście nie widać żadnego datasetu. Podłącz dysk i zaimportuj pulę (zpool import <pula>), potem spróbuj jeszcze raz." 9 "$W"
                exit 1
            fi
            "$PY" - "$TMPD/ds.tsv" "$TMPD/tree-spec.json" "Przywróć z dysku: skąd?" "$(hostname)" "$PRE" <<'PYEOF' || exit 1
import sys, json
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
        "legend": u" [x] odtwarzane razem z tym, co pod nim   dysku nie ma? zpool import",
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
                wt --title "Przywróć z dysku" --msgbox "Nic nie zaznaczono." 7 "$W"
                continue
            fi
            step=2 ;;
        2)  # ---- DOKĄD? --------------------------------------------------------------------
            i=0; GOBACK=0
            while [ "$i" -lt "${#FROM[@]}" ]; do
                def="${ANS[$i]:-$(sug "${FROM[$i]}")}"
                txt=$'Pod jaką nazwą odtworzyć na tym hoście:\n  '"${FROM[$i]}"$'\n(datasety pod nim przyjdą razem z nim)'
                geom
                if wt --title "Przywróć z dysku: dokąd? ($((i + 1))/${#FROM[@]})" --ok-button "Dalej" --cancel-button "Wstecz" \
                      --inputbox "$txt" "$(fit 6)" "$W" "$def"; then
                    [ -n "$WT_OUT" ] || continue
                    # P5 (właściciel 10-15): nazwa bez puli ("restore/home") przechodziła
                    # i dopiero polecenie odmawiało. Pula musi istnieć NA TYM hoście.
                    if ! pool_ok "$WT_OUT"; then
                        ANS[$i]="$WT_OUT"
                        geom
                        wt --title "Przywróć z dysku: zła nazwa" \
                           --msgbox "'$WT_OUT' nie zaczyna się od puli tego hosta.

Nazwa ma mieć postać <pula>/<ścieżka>, np. $(sug "${FROM[$i]}").
Pule tutaj: $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')" 11 "$W"
                        continue
                    fi
                    ANS[$i]="$WT_OUT"; i=$((i + 1))
                else
                    [ "$i" -eq 0 ] && { GOBACK=1; break; }
                    i=$((i - 1))
                fi
            done
            [ "$GOBACK" -eq 1 ] && { step=1; continue; }
            ONTO=("${ANS[@]}")
            DUP=""
            for ((i = 0; i < ${#ONTO[@]}; i++)); do
                for ((j = i + 1; j < ${#ONTO[@]}; j++)); do
                    [ "${ONTO[$i]}" = "${ONTO[$j]}" ] && DUP="${ONTO[$i]}"
                done
            done
            if [ -n "$DUP" ]; then
                geom
                wt --title "Przywróć z dysku" --msgbox "Dwa źródła mają ten sam cel ($DUP) -- podaj różne nazwy." 8 "$W"
                continue
            fi
            EXIST=()
            for o in "${ONTO[@]}"; do zfs list -H -o name -- "$o" >/dev/null 2>&1 && EXIST+=("$o"); done
            OVERWRITE=0
            if [ "${#EXIST[@]}" -gt 0 ]; then
                txt="Te cele JUŻ ISTNIEJĄ na tym hoście:"
                for o in "${EXIST[@]}"; do txt+=$'\n'"  $o"; done
                txt+=$'\n\nNadpisać je (--overwrite)? To, co tam jest, zostanie zastąpione kopią z dysku.'
                geom
                wt --title "Przywróć z dysku: cel istnieje" --yes-button "Nadpisz" --no-button "Wstecz" --defaultno \
                   --yesno "$txt" "$(fit $((${#EXIST[@]} + 5)))" "$W" || continue
                OVERWRITE=1
            fi
            step=3 ;;
        3)  # ---- Z KIEDY? ------------------------------------------------------------------
            # punkty: migawki pierwszego źródła; najnowsza pierwsza, max 50
            zfs list -H -p -t snapshot -o name,creation -s creation -d 1 -- "${FROM[0]}" 2>/dev/null \
                | tr -d '\r' | awk -F'\t' '{ n = $1; sub(/^[^@]*@/, "", n); print $2 "\t" n }' | tac | head -n 50 >"$TMPD/points.tsv"
            geom
            build_points
            if [ "${#PT_TIME[@]}" -eq 0 ]; then
                wt --title "Przywróć z dysku" --msgbox "${FROM[0]} nie ma żadnej migawki -- nie ma z czego odtworzyć." 8 "$W"
                exit 1
            fi
            wt --title "Przywróć z dysku: z kiedy?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --default-item p0 --menu "Wybierz migawkę do odzyskania." \
               "$(fit $((${#PT_TIME[@]} + 3)))" "$W" "$(lhfit ${#PT_TIME[@]} 3)" "${menu[@]}" || { step=2; continue; }
            idx="${WT_OUT#p}"
            if [ "$idx" = 0 ]; then AT=""; PT=""; else AT="${PT_AT[$idx]}"; PT="${PT_TIME[$idx]}"; fi
            geom
            wt --title "Przywróć z dysku: historia" --yes-button "Tak" --no-button "Nie" --defaultno \
               --yesno $'Przenieść też wszystkie starsze migawki (z historią)?\nNie = tylko wybrany punkt.' "$(fit 3)" "$W"
            hrc=$?
            case $hrc in
                0) HIST=1 ;;
                1) HIST=0 ;;
                *) continue ;;           # Esc itp. -> znów lista punktów
            esac
            step=4 ;;
        4)  # ---- SPRAWDŹ + POLECENIE -------------------------------------------------------
            CMD=("$ZB" restore "--from-copy=$(join_by_comma "${FROM[@]}")" "--onto=$(join_by_comma "${ONTO[@]}")")
            [ -n "$AT" ] && CMD+=("--at=$AT")
            [ "$HIST" -eq 1 ] && CMD+=("--with-history")
            [ "$OVERWRITE" -eq 1 ] && CMD+=("--overwrite")
            CMDTXT=""
            for w in "${CMD[@]}"; do CMDTXT+="${CMDTXT:+ }$(shq "$w")"; done
            {
                echo "Skąd:   dysk / inny dataset na tym hoście"
                echo "Co -> dokąd:"
                for ((i = 0; i < ${#FROM[@]}; i++)); do
                    echo "  ${FROM[$i]} -> ${ONTO[$i]}"
                    for o in ${EXIST[@]+"${EXIST[@]}"}; do [ "$o" = "${ONTO[$i]}" ] && { echo "  (NADPISUJE)"; break; }; done
                done
                if [ -n "$AT" ]; then echo "Punkt:  bieg z $PT ($TZN) -- każdy dataset: jego ostatnia migawka do $AT"; else echo "Punkt:  najnowszy"; fi
                if [ "$HIST" -eq 1 ]; then echo "Historia: tak"; else echo "Historia: nie"; fi
                echo
                echo "Polecenie:"
                echo "  $CMDTXT"
                echo
                echo "Po <Uruchom> polecenie pokaże podgląd i samo zapyta; zaszyfrowana kopia -- zapyta o klucz albo plik klucza."
            } >"$TMPD/summary.txt"
            yesno_text "$TMPD/summary.txt" "Przywróć z dysku: sprawdź" "Uruchom" "Wstecz" --defaultno || { step=3; continue; }
            run_cmd ;;
        esac
    done
fi

# ---- KROK 0: który config trzyma kopie tej relacji + jej punkty odzysku --------------------
geom
info "Przywróć $REL" "Czytam kopie i punkty odzysku..."
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
    wt --title "Nie ma kopii relacji $REL" \
       --msgbox "Na tym hoście nie ma kopii relacji $REL -- przywracać można tylko na kolektorze, który ją trzyma." 8 "$W"
    exit 1
fi

ROWC=(); ROWS=()
while IFS=$'\t' read -r c s; do [ -n "$c" ] && { ROWC+=("$c"); ROWS+=("$s"); }; done <"$TMPD/rows.tsv"
case "${ROWS[0]}" in
    *:*) h="${ROWS[0]%%:*}"; TARGET="${h#*@}" ;;
    *)   TARGET="ten host" ;;
esac

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
    info "Przywróć $REL" "Pytam $TARGET o zgodę na odzysk..."
    "$ZB" restore "$REL" --grant --config="$CFG" >"$TMPD/grant.txt" 2>/dev/null; GRANT_RC=$?
    GRANT="$(sed -n 's/^GRANT=//p' "$TMPD/grant.txt" | head -1)"
    _gl="$(sed -n 's/^LABEL=//p' "$TMPD/grant.txt" | head -1)"
    [ -n "$_gl" ] && GRANT_LABEL="$_gl"
    # Brak zgody = kod != 0 ALBO odpowiedź none/unreachable/pusta -- nie ufamy samemu kodowi.
    case "$GRANT" in ""|none|unreachable) [ "$GRANT_RC" -ne 0 ] || GRANT_RC=1 ;; esac
    if [ "$GRANT_RC" -ne 0 ]; then
        if [ "$GRANT" = none ]; then
            why="$TARGET nie wydał temu kolektorowi zgody na odzysk."
        else
            why="$TARGET nie odpowiedział na pytanie o zgodę (brak połączenia albo pakietu)."
        fi
        txt="$why Odzysk na $TARGET -- na miejsce i obok -- zostanie odrzucony.

Żeby go umożliwić, na $TARGET jako root:
  deploy.sh --allow-restore=$GRANT_LABEL
  (na miejsce, gdy trzeba nadpisać: z --replace)

Bez zgody źródła: odtwórz kopię na TYM hoście jako nowy dataset albo przejrzyj jej pliki (ekran Odzysk, Przeglądaj kopię)."
        geom
        wt --title "Przywróć $REL: brak zgody na $TARGET" --ok-button "Wybierz" --cancel-button "Wyjdź" --notags \
           --menu "$txt" "$(fit 13)" "$W" 2 \
           tutaj "Odtwórz kopię na tym hoście (bez zgody źródła)" \
           dalej "Mimo to dalej -- zgodę wydam przed uruchomieniem" || abort
        if [ "$WT_OUT" = tutaj ]; then
            rm -rf "$TMPD"
            exec bash "$HERE/tui/restore.sh" --from-copy "${ROWC[0]}"
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
        RESTORE_LAST_TREE="$TMPD/tree-last.json" "$PY" - "$TMPD/ds.tsv" "$TMPD/tree-spec.json" "Przywróć $REL: co?" "$TARGET" "${ROWC[@]}" <<'PYEOF' || exit 1
import sys, json, os
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
        "legend": u" [x] odtwarzane   [-] część   [ ] nie",
        "recursion": "flat", "hide": [], "datasets": ds, "roots": sys.argv[5:], "excl": {}}
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
            wt --title "Przywróć $REL" --msgbox "Nie mogę odczytać datasetów kopii relacji $REL (zfs list nic nie zwrócił)." 8 "$W"
            exit 1
        fi
        rm -f "$TMPD/tree-out.json"
        ${ZFS_TREE:-$PY $HERE/tui/tree.py} --spec "$TMPD/tree-spec.json" --out "$TMPD/tree-out.json" || abort
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
            wt --title "Przywróć $REL" --msgbox "Nic nie zaznaczono." 7 "$W"
            continue
        fi
        step=2 ;;
    2)  # ---- DOKĄD? ----------------------------------------------------------------------
        geom
        wt --title "Przywróć $REL: dokąd?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
           --default-item obok --menu "Gdzie odtworzyć wybrane datasety?" "$(fit 5)" "$W" "$(lhfit 2 1)" \
           obok "Obok oryginału na $TARGET -- nic nie nadpisuje" \
           miejsce "Na miejsce na $TARGET -- NADPISUJE obecne dane" || { step=1; continue; }
        DEST="$WT_OUT"
        ONTO=()
        if [ "$DEST" = obok ]; then
            BASE="${ORIG[0]%%/*}/restore"
            txt="Katalog na $TARGET, pod którym lądują odtworzone datasety (każdy pod swoją nazwą). Musi leżeć w <pula>/restore -- tylko tam zgoda na odzysk pozwala kolektorowi tworzyć."
            while :; do
                geom
                wt --title "Przywróć $REL: obok -- gdzie?" --ok-button "Dalej" --cancel-button "Wstecz" \
                   --inputbox "$txt" "$(fit $((${#txt} / (W - 8) + 3)))" "$W" "$BASE" || { BASE=""; break; }
                # P5: bez "<pula>/" polecenie odmówi dopiero na celu; tu sprawdzamy postać
                # (pula leży na $TARGET, więc jej istnienia stąd nie widać).
                case "$WT_OUT" in
                    */?*) BASE="$WT_OUT"; break ;;
                    "") ;;
                    *) BASE="$WT_OUT"; geom
                       wt --title "Przywróć $REL: zła nazwa" --msgbox "'$WT_OUT' nie ma postaci <pula>/<katalog>, np. ${ORIG[0]%%/*}/restore." 8 "$W" ;;
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
                wt --title "Przywróć $REL" --msgbox "Dwa wybrane datasety mają tę samą nazwę ($DUP) -- obok nie zmieszczą się pod jednym katalogiem. Wybierz je osobno." 9 "$W"
                step=1; continue
            fi
            while IFS= read -r o; do [ -n "$o" ] && ONTO+=("$o"); done <"$TMPD/onto.txt"
        fi
        step=3 ;;
    3)  # ---- Z KIEDY? --------------------------------------------------------------------
        # punkty: migawki wiersza, w którym leży pierwszy wybrany dataset; najnowsza pierwsza, max 50
        "$PY" - "$TMPD/plan.json" "${SEL[0]}" <<'PYEOF' 2>/dev/null | tr -d '\r' >"$TMPD/points.tsv"
import sys, json
d = json.load(open(sys.argv[1], encoding="utf-8"))
s = sys.argv[2]
best = None
for r in d.get("datasets") or []:
    c = r.get("copy") or ""
    if c and (s == c or s.startswith(c + "/")) and (best is None or len(c) > len(best.get("copy"))):
        best = r
for sn in list(reversed((best or {}).get("snapshots") or []))[:50]:
    print("%s\t%s" % (sn.get("creation"), sn.get("name")))
PYEOF
        build_points
        if [ "${#PT_TIME[@]}" -eq 0 ]; then
            geom
            wt --title "Przywróć $REL" --msgbox "Kopia nie ma żadnego punktu odzysku." 7 "$W"
            exit 1
        fi
        geom
        wt --title "Przywróć $REL: z kiedy?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
           --default-item p0 --menu "Punkt odzysku (czas utworzenia kopii, strefa tego hosta: $TZN). Datasety potomne dostają swój najbliższy punkt z tej chwili lub wcześniejszy." \
           "$(fit $((${#PT_TIME[@]} + 3)))" "$W" "$(lhfit ${#PT_TIME[@]} 3)" "${menu[@]}" || { step=2; continue; }
        idx="${WT_OUT#p}"
        if [ "$idx" = 0 ]; then AT=""; PT=""; else AT="${PT_AT[$idx]}"; PT="${PT_TIME[$idx]}"; fi
        step=4 ;;
    4)  # ---- SPRAWDŹ + POLECENIE ---------------------------------------------------------
        CMD=("$ZB" restore "$REL")
        if [ "$DEST" = obok ]; then
            CMD+=("$REL" "--source=$(join_by_comma "${SEL[@]}")" "--onto=$(join_by_comma "${ONTO[@]}")")
        elif [ "$WHOLE" != 1 ]; then
            CMD+=("--source=$(join_by_comma "${SEL[@]}")")
        fi
        [ -n "$AT" ] && CMD+=("--at=$AT")
        CMD+=("--config=$CFG")
        CMDTXT=""
        for w in "${CMD[@]}"; do CMDTXT+="${CMDTXT:+ }$(shq "$w")"; done
        {
            echo "Skąd:   relacja $REL (kopie na tym kolektorze)"
            if [ "$WHOLE" = 1 ]; then echo "Co:     cała relacja"; else echo "Co:     ${#SEL[@]} dataset(ów)"; fi
            for o in "${ORIG[@]}"; do echo "          $o"; done
            if [ "$DEST" = obok ]; then
                echo "Dokąd:  obok, na $TARGET:"
                for o in "${ONTO[@]}"; do echo "          $o"; done
            else
                echo "Dokąd:  NA MIEJSCE na $TARGET -- NADPISUJE"
            fi
            if [ -n "$AT" ]; then echo "Punkt:  bieg z $PT ($TZN) -- każdy dataset: jego ostatnia migawka do $AT"; else echo "Punkt:  najnowszy"; fi
            echo
            echo "Polecenie:"
            echo "  $CMDTXT"
            echo
            if [ "$TARGET" = "ten host" ]; then
                # relacja lokalna: zrodlo, kopia i cel na tym hoscie -- restore nie pyta o zgode
                echo "Relacja lokalna: kopia i cel są na tym hoście, zgoda nie jest potrzebna."
            elif [ "$GRANT_RC" -eq 0 ] && [ -n "$GRANT" ]; then
                echo "Zgoda $TARGET: $GRANT  (create = obok, rewind = na miejsce ze wspólnym punktem, replace = nadpisanie bez niego)"
            elif [ "$DEST" = obok ]; then
                echo "Wymaga zgody na $TARGET: deploy.sh --allow-restore=$GRANT_LABEL"
            else
                echo "Wymaga zgody na $TARGET: deploy.sh --allow-restore=$GRANT_LABEL (z --replace, gdy nie ma wspólnego punktu)."
            fi
            [ "$TARGET" = "ten host" ] || echo "($GRANT_LABEL = nazwa tego kolektora na $TARGET; lista: ls /var/lib/zfs-snapshot-all/relationships)"
            echo "Po <Uruchom> polecenie pokaże plan i samo zapyta, zanim cokolwiek nadpisze."
        } >"$TMPD/summary.txt"
        yesno_text "$TMPD/summary.txt" "Przywróć $REL: sprawdź" "Uruchom" "Wstecz" --defaultno || { step=3; continue; }
        run_cmd ;;
    esac
done
