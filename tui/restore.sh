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
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka, ZFS_TREE =
# program drzewa (jak w basket_step), ZFS_CONF_DIR (domyślnie /etc/zfs-snapshot-all), PYTHON.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "restore: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
REL="${1:-}"
[ -n "$REL" ] || { echo "użycie: restore.sh RELACJA" >&2; exit 2; }
CONFDIR="${ZFS_CONF_DIR:-/etc/zfs-snapshot-all}"
WT_BACKTITLE="Przywracanie z relacji $REL -- $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

abort() { clear 2>/dev/null; echo "restore: przerwane, nic nie zmieniono"; exit 1; }
join_by_comma() { local IFS=,; echo "$*"; }

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

step=1
while :; do
    case $step in
    1)  # ---- CO? -------------------------------------------------------------------------
        : >"$TMPD/ds.tsv"
        for c in "${ROWC[@]}"; do zfs list -H -p -o name,used,type -r "$c" 2>/dev/null >>"$TMPD/ds.tsv"; done
        "$PY" - "$TMPD/ds.tsv" "$TMPD/tree-spec.json" "Przywróć $REL: co?" "$TARGET" "${ROWC[@]}" <<'PYEOF' || exit 1
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
spec = {"title": sys.argv[3], "host": sys.argv[4], "show_mode": False, "no_exc": False,
        "recursion": "flat", "hide": [], "datasets": ds, "roots": sys.argv[5:], "excl": {}}
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
           --radiolist "Gdzie odtworzyć wybrane datasety?" "$(fit 5)" "$W" "$(lhfit 2 1)" \
           obok "Obok oryginału na $TARGET -- nic nie nadpisuje" ON \
           miejsce "Na miejsce na $TARGET -- NADPISUJE obecne dane" OFF || { step=1; continue; }
        DEST="$WT_OUT"
        ONTO=()
        if [ "$DEST" = obok ]; then
            BASE="${ORIG[0]%%/*}/restore"
            txt="Katalog na $TARGET, pod którym lądują odtworzone datasety (każdy pod swoją nazwą). Musi leżeć w <pula>/restore -- tylko tam zgoda na odzysk pozwala kolektorowi tworzyć."
            while :; do
                geom
                wt --title "Przywróć $REL: obok -- gdzie?" --ok-button "Dalej" --cancel-button "Wstecz" \
                   --inputbox "$txt" "$(fit $((${#txt} / (W - 8) + 3)))" "$W" "$BASE" || { BASE=""; break; }
                [ -n "$WT_OUT" ] && { BASE="$WT_OUT"; break; }
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
        PT_TIME=(); menu=()
        while IFS=$'\t' read -r cr nm; do
            [ -n "$cr" ] || continue
            tm=$(date -d "@$cr" '+%Y-%m-%d %H:%M:%S')
            case "$nm" in *_*) tier="${nm#*_}"; tier="${tier%%_*}" ;; *) tier="$nm" ;; esac
            lbl="$tm  $tier"
            [ "${#PT_TIME[@]}" -eq 0 ] && lbl="$lbl  (najnowszy)"
            menu+=("p${#PT_TIME[@]}" "$(clip_label "$lbl" $((W - 14)))" "$([ "${#PT_TIME[@]}" -eq 0 ] && echo ON || echo OFF)")
            PT_TIME+=("$tm")
        done <"$TMPD/points.tsv"
        if [ "${#PT_TIME[@]}" -eq 0 ]; then
            geom
            wt --title "Przywróć $REL" --msgbox "Kopia nie ma żadnego punktu odzysku." 7 "$W"
            exit 1
        fi
        geom
        wt --title "Przywróć $REL: z kiedy?" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
           --radiolist "Punkt odzysku (czas utworzenia kopii). Datasety pod spodem dostają swój najbliższy punkt z tej chwili lub wcześniejszy." \
           "$(fit $((${#PT_TIME[@]} + 3)))" "$W" "$(lhfit ${#PT_TIME[@]} 3)" "${menu[@]}" || { step=2; continue; }
        idx="${WT_OUT#p}"
        if [ "$idx" = 0 ]; then AT=""; else AT="${PT_TIME[$idx]}"; fi
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
            echo "Punkt:  ${AT:-najnowszy}"
            echo
            echo "Polecenie:"
            echo "  $CMDTXT"
            echo
            if [ "$DEST" = obok ]; then
                echo "Wymaga zgody na $TARGET: deploy.sh --allow-restore."
            else
                echo "Wymaga zgody na $TARGET: deploy.sh --allow-restore (z --replace, gdy nie ma wspólnego punktu)."
            fi
            echo "Po <Uruchom> polecenie pokaże plan i samo zapyta, zanim cokolwiek nadpisze."
        } >"$TMPD/summary.txt"
        yesno_text "$TMPD/summary.txt" "Przywróć $REL: sprawdź" "Uruchom" "Wstecz" --defaultno || { step=3; continue; }
        # ---- URUCHOM ---------------------------------------------------------------------
        clear 2>/dev/null
        echo "\$ $CMDTXT"; echo
        "${CMD[@]}" 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
        [ -n "${ZFS_TUI_LOG:-}" ] && { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null
        echo
        if [ "$RC" -eq 0 ]; then echo "GOTOWE."
        else echo "NIE WYSZŁO (rc=$RC) -- komunikat polecenia powyżej."; fi
        read -r -p "Enter = powrót do GUI " _ </dev/tty 2>/dev/null || true
        exit "$RC" ;;
    esac
done
