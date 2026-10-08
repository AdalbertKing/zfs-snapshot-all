#!/bin/bash
# edit-relation.sh NAZWA -- zmiana zainstalowanej relacji w oknach whiptail ('e' na F3).
#
# Pierwsze okno: CO zmienić -- szablon (edit-relation), dodać dataset ze źródła
# (add-source) albo usunąć dataset z relacji (remove-source). Każda ścieżka
# pokazuje PLAN swojego czasownika i po "WYKONAJ" uruchamia go z --yes.
#
# Do 2026-10-07 jedyną drogą zmiany relacji było usunięcie i założenie od nowa. Okno
# NIE ma własnej logiki: pyta o to, o co pyta `zfs-backup.sh edit-relation` (szablon
# celu, szablon retencji źródła), pokazuje PLAN tego czasownika (--plan: generacja,
# gen-cron, próba pobrania, sprawdzenie praw -- bez zmian) i po "WYKONAJ" uruchamia
# go z --yes. Czego czasownik odmawia (inna rodzina migawek, inny kształt źródła),
# odmawia tu tak samo, tymi samymi słowami.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "edit-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "użycie: edit-relation.sh NAZWA" >&2; exit 2; }
WT_BACKTITLE="Zmiana relacji $NAME -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT

geom
info "Zmień relację $NAME" "Czytam relację i szablony..."
"$ZB" status "$NAME" --json >"$TMPD/st.json" 2>/dev/null
"$ZB" list-profiles --json >"$TMPD/prof.json" 2>"$TMPD/prof.err" || {
    wt --title "Szablony niedostępne" --msgbox "list-profiles nie odpowiedział:\n$(tail -3 "$TMPD/prof.err")" 12 "$W"; exit 1; }
# st.tsv: stan <TAB> profil <TAB> profil źródła ; prof.tsv: nazwa <TAB> opis (słowa z tui/zfs-tui.py)
"$PY" - "$TMPD/st.json" "$TMPD/prof.json" "$HERE/tui/zfs-tui.py" "$TMPD" <<'PYEOF'
import sys, json, importlib.util
spec = importlib.util.spec_from_file_location("zfs_tui", sys.argv[3])
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
    st = (st.get("relations") or [{}])[0]
except Exception:
    st = {}
with open(sys.argv[4] + "/st.tsv", "w", encoding="utf-8", newline="\n") as f:
    f.write("%s\t%s\t%s\t%s\t%s\n" % (st.get("state") or "-", st.get("profile") or "-", st.get("source_profile") or "-",
                                        st.get("peer_host") or "-",
                                        # "konto@host:dataset" -> "dataset": add-/remove-source biorą sam dataset
                                        ",".join(x.rsplit(":", 1)[-1] for x in (st.get("sources") or [])) or "-"))
d = json.load(open(sys.argv[2], encoding="utf-8"))
rows = []
for p in d.get("profiles", []):
    n = p.get("name") or ""
    if not n or "-src-" in n:
        continue
    w = tui.profile_words(p)
    rows.append((n, "%s  [%s]" % (w["retention"], w["mech"])))
rows.sort(key=lambda r: r[0].lower())
with open(sys.argv[4] + "/prof.tsv", "w", encoding="utf-8", newline="\n") as f:
    for n, t in rows:
        f.write("%s\t%s\n" % (n, t))
PYEOF
IFS=$'\t' read -r STATE CUR_P CUR_S PEER SRCS <"$TMPD/st.tsv" || { STATE=-; CUR_P=-; CUR_S=-; PEER=-; SRCS=-; }
[ "$CUR_P" = - ] && CUR_P=""; [ "$CUR_S" = - ] && CUR_S=""
if [ "$STATE" != active ]; then
    wt --title "Nie da się zmienić '$NAME'" --msgbox "Relacja '$NAME' jest w stanie '${STATE}'.\nZmieniać można tylko relację zainstalowaną (active)." 10 "$W"
    exit 1
fi

# Plan czasownika, okno z planem, WYKONAJ -- wspólne dla dodania i usunięcia datasetu.
run_verb_with_plan() {   # <tytuł> <argv...> (bez --yes)
    local title="$1"; shift
    info "$title" "Liczę plan..."
    if ! "$@" >"$TMPD/vplan.txt" 2>&1; then
        tail -6 "$TMPD/vplan.txt" | fold -s -w $((W - 6)) >"$TMPD/why.txt"
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
        return 1
    fi
    { echo "PLAN -- nic jeszcze nie zostało zmienione:"; echo; grep -v '^plan only' "$TMPD/vplan.txt"; echo
      echo "Komenda:  $(for a in "$@"; do printf '%s ' "$(shq "$a")"; done)--yes"; } >"$TMPD/vplan2.txt"
    yesno_text "$TMPD/vplan2.txt" "$title -- plan" "WYKONAJ" "Wstecz" --defaultno || return 1
    clear 2>/dev/null
    echo "\$ $(for a in "$@"; do printf '%s ' "$(shq "$a")"; done)--yes"; echo
    "$@" --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    if [ -n "${ZFS_TUI_LOG:-}" ]; then { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :; fi
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: $title (rc=$RC). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- powód w linii FATAL powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
}
while :; do
    geom
    wt --title "Zmień relację $NAME" --ok-button "Dalej" --cancel-button "Anuluj" --notags --default-item szablon \
       --menu "Relacja $NAME ze źródła ${PEER}.\n$(clip_label "Datasety ($(printf '%s' "$SRCS" | tr ',' '\n' | grep -vc '^-\?$')): ${SRCS//,/, }" $((W - 6)))\nCo zmienić?" 14 "$W" 4 \
       szablon "Szablon (retencja, harmonogramy, retencja źródła)" \
       dodaj   "Dodaj dataset ze źródła" \
       usun    "Usuń dataset z relacji (kopie zostają)" \
       config  "Edytuj config w edytorze (jak crontab -e)" || { clear 2>/dev/null; echo "edit-relation: przerwane, nic nie zmieniono"; exit 1; }
    ACTION="$WT_OUT"
    case "$ACTION" in
        szablon) break ;;
        config)
            # edit-config (2026-10-08): edytor dostaje caly terminal, jak crontab -e;
            # czasownik sam pyta o instalacje i pokazuje, co zrobi na zrodle.
            clear 2>/dev/null
            "$ZB" edit-config "$NAME"; RC=$?
            echo "=== edit-config zakończony (rc=$RC). Enter = dalej"
            [ -t 0 ] && read -r _
            exit "$RC" ;;
        dodaj)
            info "Dodaj dataset" "Czytam datasety na $PEER..."
            if ! "$ZB" list-datasets "$PEER" --json >"$TMPD/ds.json" 2>"$TMPD/ds.err"; then
                wt --title "Lista datasetów niedostępna" --msgbox "list-datasets $PEER nie odpowiedział:\n$(tail -3 "$TMPD/ds.err")" 12 "$W"; continue
            fi
            "$PY" - "$TMPD/ds.json" "$SRCS" >"$TMPD/ds.tsv" <<'PYEOF'
import sys, json
have = [x for x in sys.argv[2].split(",") if x and x != "-"]
for d in json.load(open(sys.argv[1], encoding="utf-8")).get("datasets") or []:
    n = d.get("name") or ""
    if "/" not in n or any(n == h or n.startswith(h + "/") for h in have):
        continue    # pula sama w sobie i to, co relacja już ma (z dziećmi) -- nie do dodania
    print("%s\t%s" % (n, d.get("type") or ""))
PYEOF
            items=()
            while IFS=$'\t' read -r n t; do [ -n "$n" ] && items+=("$n" "$(clip_label "$n  ($t)" $((W - 10)))"); done <"$TMPD/ds.tsv"
            [ "${#items[@]}" -gt 0 ] || { wt --title "Nie ma czego dodać" --msgbox "Na $PEER nie ma datasetu spoza tej relacji." 8 "$W"; continue; }
            wt --title "Dodaj dataset do $NAME" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --menu "Dataset ze źródła $PEER. Wchodzi z dziećmi; pierwsza (pełna) kopia idzie od razu,\nresztą zajmuje się cron. Pozostałe datasety relacji zostają nietknięte." \
               "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$(lhfit $((${#items[@]} / 2)) 3)" "${items[@]}" || continue
            run_verb_with_plan "Dodaj $WT_OUT do $NAME" "$ZB" add-source "$NAME" "$WT_OUT" || continue ;;
        usun)
            items=()
            for n in ${SRCS//,/ }; do [ "$n" != - ] && items+=("$n" "$n"); done
            [ "${#items[@]}" -gt 0 ] || { wt --title "Brak datasetów" --msgbox "Relacja nie ma datasetów do usunięcia." 8 "$W"; continue; }
            if [ "${#items[@]}" -eq 2 ]; then
                wt --title "Ostatni dataset" --msgbox "To jedyny dataset relacji. Relację bez datasetów usuwa się w całości: Del na F3." 9 "$W"; continue
            fi
            wt --title "Usuń dataset z $NAME" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --menu "Dataset przestaje być kopiowany: źródło odbiera prawa, tu znikają jego zadania.\nKopie, które już są na tym hoście, ZOSTAJĄ." \
               "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || continue
            run_verb_with_plan "Usuń $WT_OUT z $NAME" "$ZB" remove-source "$NAME" "$WT_OUT" || continue ;;
    esac
done

PROFILE="${CUR_P:-default}"; SRCP="${CUR_S:-__same__}"
step=1
while :; do
    geom
    if [ "$step" -eq 1 ]; then
        items=()
        while IFS=$'\t' read -r n t; do
            [ -n "$n" ] || continue
            mark=""; [ "$n" = "$CUR_P" ] && mark="[obecny] "
            items+=("$n" "$(clip_label "$mark$n  $t" $((W - 10)))")
        done <"$TMPD/prof.tsv"
        wt --title "Zmień relację $NAME -- 1/2 szablon celu" --ok-button "Dalej" --cancel-button "Anuluj" --notags --default-item "$PROFILE" \
           --menu "Obecny szablon: ${CUR_P:-<nie zapisany>}\nSekcje relacji zostaną wygenerowane od nowa z wybranego szablonu\n(retencja, harmonogramy). Dane nie są przenoszone, seed nie jest potrzebny.\nTen sam szablon = odświeżenie (rozrzut minut, retencja źródła per szczebel)." \
           "$(fit $((${#items[@]} / 2 + 5)))" "$W" "$(lhfit $((${#items[@]} / 2)) 4)" "${items[@]}" || { clear 2>/dev/null; echo "edit-relation: przerwane, nic nie zmieniono"; exit 1; }
        PROFILE="$WT_OUT"; step=2; continue
    fi
    if [ "$step" -eq 2 ]; then
        items=(__same__ "taka sama jak w celu (bez asymetrii)")
        while IFS=$'\t' read -r n t; do
            [ -n "$n" ] || continue
            mark=""; [ "$n" = "$CUR_S" ] && mark="[obecny] "
            items+=("$n" "$(clip_label "$mark$n  $t" $((W - 10)))")
        done <"$TMPD/prof.tsv"
        wt --title "Zmień relację $NAME -- 2/2 retencja na źródle" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item "$SRCP" \
           --menu "Obecnie: ${CUR_S:-taka sama jak w celu}\nIle migawek trzymać na ŹRÓDLE. Szablon źródła musi mieć te same rodziny\ni ten sam mechanizm co szablon celu (inaczej czasownik odmówi)." \
           "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$(lhfit $((${#items[@]} / 2)) 3)" "${items[@]}" || { step=1; continue; }
        SRCP="$WT_OUT"
    fi
    ARGV=("$ZB" edit-relation "$NAME" "--profile=$PROFILE")
    if [ "$SRCP" = __same__ ]; then ARGV+=("--source-profile="); else ARGV+=("--source-profile=$SRCP"); fi
    info "Zmień relację $NAME" "Liczę plan (generacja, próba pobrania, prawa na źródle)..."
    if ! "${ARGV[@]}" --plan >"$TMPD/plan.txt" 2>&1; then
        grep -E '^FATAL' "$TMPD/plan.txt" | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)) >"$TMPD/why.txt"
        [ -s "$TMPD/why.txt" ] || tail -5 "$TMPD/plan.txt" >"$TMPD/why.txt"
        wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(cat "$TMPD/why.txt")" "$(fit "$(grep -c '' "$TMPD/why.txt")")" "$W"
        step=1; continue
    fi
    # Plan w skrócie: podsumowanie czasownika + linie crona TEJ relacji (-/+), każda jako
    # "minuta godzina ... | etykieta | retencja". Pełny diff jest w dzienniku.
    "$PY" - "$TMPD/plan.txt" "$NAME" <<'PYEOF' >"$TMPD/plan2.txt"
import sys, re
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
name = sys.argv[2]
print("PLAN -- nic jeszcze nie zostało zmienione:\n")
show = False
for l in lines:
    if l.startswith("Edycja relacji:") or l.startswith("UWAGA:"):
        show = True
    if show:
        if not l.strip():
            show = False
            continue
        print(l)
# Tylko NOWE zadania (+) i liczba zastępowanych (-): pełne -/+ nie mieściło się w
# oknie, a okno z przewijaniem trzyma fokus na tekście i Enter nie trafia w
# WYKONAJ (zmierzone jazdą po pty na pve10, 2026-10-07). Monitory bez zmian
# rytmu (*/15) nie są wypisywane.
crontab = False
gone = 0
new = []
for l in lines:
    if "co sie zmieni w crontabie" in l:
        crontab = True; continue
    if not crontab or not re.match(r"^\s+[-+]\S", l) or (" -L %s " % name) not in l:
        continue
    sign = l.strip()[0]
    body = l.strip()[1:]
    if "check-snap-age" in body:
        continue
    if sign == "-":
        gone += 1
        continue
    f = body.split()
    when = " ".join(f[:5])
    m = re.search(r'zfs-job\.sh "([^"]*)"', body)
    lbl = m.group(1).split(" ", 1)[-1] if m else "?"
    lbl = re.sub(r"^profile__.*?__", "", lbl)
    r = re.search(r'\s(-[HDWMY]\d+)\s*$', body)
    new.append("  %-14s %s%s" % (when, lbl, ("  " + r.group(1)) if r else ""))
if new or gone:
    print("\nZadania tej relacji po zmianie (zastępują %d dotychczasowych):" % gone)
    for x in new:
        print(x)
else:
    print("\nZadania w cronie: bez zmian.")
PYEOF
    echo >>"$TMPD/plan2.txt"
    echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes" >>"$TMPD/plan2.txt"
    yesno_text "$TMPD/plan2.txt" "Zmień relację $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || { step=1; continue; }
    clear 2>/dev/null
    echo "\$ $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"; echo
    "${ARGV[@]}" --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    if [ -n "${ZFS_TUI_LOG:-}" ]; then
        { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
    fi
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: relacja '$NAME' zmieniona (rc=$RC). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- nic nie zainstalowano; powód w linii FATAL powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
done
