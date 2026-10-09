#!/bin/bash
# edit-relation.sh NAZWA -- zmiana zainstalowanej relacji w oknach whiptail ('e' na F3).
#
# Pierwsze okno: CO zmienić (właściciel 2026-10-09, uwaga 5):
#   1. Dodaj do kopii dataset ze źródła          (add-source)
#   2. Usuń z kopii dataset                      (remove-source)
#   3. Szablon -- gotowy szablon dla celu        (edit-relation --profile)
#   4. Harmonogram kopii i retencja -- tabela    (ukryty szablon relacji, edit-relation)
#   5. Ręczna edycja konfigu                     (edit-config)
#   6. Zapisz ustawienia relacji jako szablon    (save-profile, zwykły szablon na F5)
# Po 3 i 4 retencję ŹRÓDŁA ustawia to samo okno-tabela co w kreatorze relacji
# (tui/retention-lib.sh; uwaga 10: dla źródła nigdy druga lista szablonów).
#
# Okno NIE ma własnej logiki: pokazuje PLAN czasownika (--plan: generacja, gen-cron,
# próba pobrania, sprawdzenie praw -- bez zmian) i po "WYKONAJ" uruchamia go z --yes.
# Czego czasownik odmawia, odmawia tu tak samo, tymi samymi słowami.
#
# UKRYTY SZABLON RELACJI (P4): "Harmonogram kopii i retencja" zapisuje wybory z tabeli
# jako relacja-<NAZWA> (save-profile --hidden; F5 go nie pokazuje). Gdy plan nie
# zostanie wykonany, poprzednia treść tego pliku wraca (albo plik znika, jeśli go nie
# było) -- przerwana zmiana nie zostawia szablonu, który mówi co innego niż relacja.
#
# Środowisko (testy): ZFS_BACKUP = ścieżka do zfs-backup.sh, WHIPTAIL = binarka.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZB="${ZFS_BACKUP:-$HERE/zfs-backup.sh}"
. "$HERE/tui/wt-lib.sh" || { echo "edit-relation: brak $HERE/tui/wt-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
. "$HERE/tui/retention-lib.sh" || { echo "edit-relation: brak $HERE/tui/retention-lib.sh -- checkout jest niekompletny" >&2; exit 1; }
NAME="${1:-}"
[ -n "$NAME" ] || { echo "użycie: edit-relation.sh NAZWA" >&2; exit 2; }
WT_BACKTITLE="Zmiana relacji $NAME -- kolektor $(hostname)"
TMPD="$(mktemp -d)" || exit 1
HNAME="relacja-$NAME"     # ukryty szablon tej relacji
HIDDEN_DIRTY=0; DONE=0; HBACKUP=""; HFILE=""
restore_hidden() {
    [ "$HIDDEN_DIRTY" -eq 1 ] && [ "$DONE" -ne 1 ] || return 0
    if [ -n "$HBACKUP" ] && [ -n "$HFILE" ]; then
        cp -p "$HBACKUP" "$HFILE" 2>/dev/null
    else
        "$ZB" delete-profile "$HNAME" --yes >/dev/null 2>&1
    fi
}
trap 'restore_hidden; rm -rf "$TMPD"' EXIT

# st.tsv: stan, profil, profil źródła, peer, datasety; prof.tsv: nazwa <TAB> opis (bez
# ukrytych i pochodnych -src-); prof.json.tiers: szczeble do okna retencji źródła;
# hfile.txt: plik ukrytego szablonu tej relacji (jeśli jest).
load_lists() {
    "$ZB" list-profiles --json >"$TMPD/prof.json" 2>"$TMPD/prof.err" || return 1
    "$PY" - "$TMPD/st.json" "$TMPD/prof.json" "$HERE/tui/zfs-tui.py" "$TMPD" "$HNAME" <<'PYEOF'
import sys, json, re, importlib.util
spec = importlib.util.spec_from_file_location("zfs_tui", sys.argv[3])
tui = importlib.util.module_from_spec(spec); spec.loader.exec_module(tui)
tmpd, hname = sys.argv[4], sys.argv[5]
try:
    st = json.load(open(sys.argv[1], encoding="utf-8"))
    st = (st.get("relations") or [{}])[0]
except Exception:
    st = {}
with open(tmpd + "/st.tsv", "w", encoding="utf-8", newline="\n") as f:
    f.write("%s\t%s\t%s\t%s\t%s\n" % (st.get("state") or "-", st.get("profile") or "-", st.get("source_profile") or "-",
                                        st.get("peer_host") or "-",
                                        # "konto@host:dataset" -> "dataset": add-/remove-source biorą sam dataset
                                        ",".join(x.rsplit(":", 1)[-1] for x in (st.get("sources") or [])) or "-"))
d = json.load(open(sys.argv[2], encoding="utf-8"))
rows = []
with open(tmpd + "/prof.json.tiers", "w", encoding="utf-8", newline="\n") as tf, \
     open(tmpd + "/hfile.txt", "w", encoding="utf-8", newline="\n") as hf:
    for p in d.get("profiles", []):
        n = p.get("name") or ""
        for t in p.get("tiers", []):
            if t.get("keep"):
                tf.write("%s\t%s\t%s\t%s\tkeep\n" % (n, t.get("name", "-"), t.get("pattern") or "-", t["keep"]))
            elif t.get("retain"):
                m = re.match(r"^-([hdwmy])([0-9]+)$", t["retain"])
                if m:
                    tf.write("%s\t%s\t%s\t%s\tretain:%s\n" % (n, t.get("name", "-"), t.get("pattern") or "-", m.group(2), m.group(1)))
        if n == hname:
            hf.write((p.get("file") or "") + "\n")
        if not n or "-src-" in n or p.get("hidden"):
            continue
        w = tui.profile_words(p)
        rows.append((n, w["retention"], w["mech"]))
rows.sort(key=lambda r: r[0].lower())
# Kolumny o STAŁEJ szerokości (uwaga 23, 2026-10-08): nazwa, co trzyma, [rodzaj].
wn = max([len(r[0]) for r in rows] + [1])
wr = max([len(r[1]) for r in rows] + [1])
with open(tmpd + "/prof.tsv", "w", encoding="utf-8", newline="\n") as f:
    for n, ret, mech in rows:
        f.write("%s\t%-*s  %-*s  [%s]\n" % (n, wn, n, wr, ret, mech))
PYEOF
}

geom
info "Zmień relację $NAME" "Czytam relację i szablony..."
"$ZB" status "$NAME" --json >"$TMPD/st.json" 2>/dev/null
load_lists || { wt --title "Szablony niedostępne" --msgbox "list-profiles nie odpowiedział:\n$(tail -3 "$TMPD/prof.err")" 12 "$W"; exit 1; }
IFS=$'\t' read -r STATE CUR_P CUR_S PEER SRCS <"$TMPD/st.tsv" || { STATE=-; CUR_P=-; CUR_S=-; PEER=-; SRCS=-; }
# Relacja lokalna (bez peera): źródłem jest ten host -- lista datasetów bez adresu.
SRCHOST="$PEER"; LDS_ARGS=("$PEER"); HOST="$PEER"
if [ "$PEER" = - ]; then SRCHOST="tego hosta ($(hostname -s 2>/dev/null || hostname))"; LDS_ARGS=(); HOST="$SRCHOST"; fi
[ "$CUR_P" = - ] && CUR_P=""; [ "$CUR_S" = - ] && CUR_S=""
if [ "$STATE" != active ]; then
    wt --title "Nie da się zmienić '$NAME'" --msgbox "Relacja '$NAME' jest w stanie '${STATE}'.\nZmieniać można tylko relację zainstalowaną (active)." 10 "$W"
    exit 1
fi
cur_words() {   # słowa o obecnym szablonie celu
    if [ "$CUR_P" = "$HNAME" ]; then echo "własne ustawienia relacji (tabela szczebli)"; else echo "${CUR_P:-<nie zapisany>}"; fi
}

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

# Liczby źródła do okna: obecny szablon źródła, dopasowany po nazwie szczebla do szablonu
# celu (szczebel, którego źródło nie ma = 0). Tylko gdy cel się nie zmienił.
src_prefill() {
    SRCKEEP=""
    [ -n "$CUR_S" ] && [ "$PROFILE" = "$CUR_P" ] || return 0
    local -a v=(); local n t p k m sv
    while IFS=$'\t' read -r n t p k m; do
        [ "$n" = "$PROFILE" ] || continue
        sv=$(awk -F'\t' -v s="$CUR_S" -v t="$t" '$1==s && $2==t {print $4; exit}' "$TMPD/prof.json.tiers")
        v+=("${sv:-0}")
    done <"$TMPD/prof.json.tiers"
    [ "${#v[@]}" -gt 0 ] && SRCKEEP="$PROFILE:${v[*]}"
}

ACTION=""
while :; do
    geom
    wt --title "Zmień relację $NAME" --ok-button "Dalej" --cancel-button "Anuluj" --notags --default-item harm \
       --menu "Relacja $NAME ze źródła ${SRCHOST}.  Szablon: $(cur_words)\n$(clip_label "Datasety ($(printf '%s' "$SRCS" | tr ',' '\n' | grep -vc '^-\?$')): ${SRCS//,/, }" $((W - 6)))\nCo zmienić?" 16 "$W" 6 \
       dodaj   "Dodaj do kopii dataset ze źródła" \
       usun    "Usuń z kopii dataset (kopie zostają)" \
       szablon "Szablon -- gotowy szablon dla celu, potem retencja źródła" \
       harm    "Harmonogram kopii i retencja -- tabela szczebli" \
       config  "Ręczna edycja konfigu (jak crontab -e)" \
       zapisz  "Zapisz ustawienia relacji jako szablon (F5)" || { clear 2>/dev/null; echo "edit-relation: przerwane, nic nie zmieniono"; exit 1; }
    ACTION="$WT_OUT"
    case "$ACTION" in
        szablon|harm) break ;;
        config)
            # edit-config (2026-10-08): edytor dostaje caly terminal, jak crontab -e;
            # czasownik sam pyta o instalacje i pokazuje, co zrobi na zrodle.
            clear 2>/dev/null
            "$ZB" edit-config "$NAME"; RC=$?
            # 3 = zamkniety bez zmian: nic do czytania, wracamy od razu (uwaga 22)
            [ "$RC" -eq 3 ] && exit 0
            echo "=== edit-config zakończony (rc=$RC). Enter = dalej"
            [ -t 0 ] && read -r _
            exit "$RC" ;;
        zapisz)
            # Z RELACJI SZABLON (właściciel 2026-10-09): kopia jej szablonu celu pod nową
            # nazwą, zwykła (bez znaku "ukryty") -- pojawi się na F5 i w kreatorze.
            [ -n "$CUR_P" ] || { wt --title "Brak szablonu" --msgbox "Relacja '$NAME' nie ma zapisanego szablonu -- nie ma czego skopiować." 8 "$W"; continue; }
            wt --title "Zapisz jako szablon" --ok-button "Dalej" --cancel-button "Wstecz" \
               --inputbox "Nazwa nowego szablonu (litery, cyfry, . _ -).\nTrzyma i robi migawki tak jak relacja $NAME teraz: $(cur_words)." 10 "$W" "$NAME-szablon" || continue
            n="${WT_OUT// /}"
            case "$n" in ''|*[!A-Za-z0-9._-]*) wt --title "Zła nazwa" --msgbox "'$WT_OUT' -- tylko litery, cyfry, kropka, minus, podkreślenie." 8 "$W"; continue ;; esac
            if awk -F'\t' -v n="$n" '$1==n{f=1} END{exit !f}' "$TMPD/prof.tsv"; then
                wt --title "Nazwa zajęta" --msgbox "Szablon '$n' już jest. Podaj inną nazwę." 8 "$W"; continue
            fi
            info "Zapisz jako szablon" "Zapisuję szablon $n..."
            if out=$("$ZB" save-profile "--from=$CUR_P" "--as=$n" "--description=Ustawienia relacji $NAME" 2>&1); then
                wt --title "Szablon zapisany" --msgbox "Szablon '$n' zapisany -- jest na F5 i w kreatorze nowej relacji." 8 "$W"
                load_lists
            else
                wt --title "Czasownik odmówił -- nic nie zapisano" --msgbox "$(printf '%s' "$out" | tail -6 | fold -s -w $((W - 6)))" 14 "$W"
            fi
            continue ;;
        dodaj)
            info "Dodaj dataset" "Czytam datasety z $SRCHOST..."
            if ! "$ZB" list-datasets ${LDS_ARGS[@]+"${LDS_ARGS[@]}"} --json >"$TMPD/ds.json" 2>"$TMPD/ds.err"; then
                wt --title "Lista datasetów niedostępna" --msgbox "list-datasets $SRCHOST nie odpowiedział:\n$(tail -3 "$TMPD/ds.err")" 12 "$W"; continue
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
            [ "${#items[@]}" -gt 0 ] || { wt --title "Nie ma czego dodać" --msgbox "Na $SRCHOST nie ma datasetu spoza tej relacji." 8 "$W"; continue; }
            wt --title "Dodaj do kopii dataset ze źródła" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --menu "Dataset ze źródła $SRCHOST. Wchodzi z dziećmi; pierwsza (pełna) kopia idzie od razu,\nresztą zajmuje się cron. Pozostałe datasety relacji zostają nietknięte." \
               "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$(lhfit $((${#items[@]} / 2)) 3)" "${items[@]}" || continue
            run_verb_with_plan "Dodaj $WT_OUT do $NAME" "$ZB" add-source "$NAME" "$WT_OUT" || continue ;;
        usun)
            items=()
            for n in ${SRCS//,/ }; do [ "$n" != - ] && items+=("$n" "$n"); done
            [ "${#items[@]}" -gt 0 ] || { wt --title "Brak datasetów" --msgbox "Relacja nie ma datasetów do usunięcia." 8 "$W"; continue; }
            if [ "${#items[@]}" -eq 2 ]; then
                wt --title "Ostatni dataset" --msgbox "To jedyny dataset relacji. Relację bez datasetów usuwa się w całości: Del na F3." 9 "$W"; continue
            fi
            wt --title "Usuń z kopii dataset" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
               --menu "Dataset przestaje być kopiowany: źródło odbiera prawa, tu znikają jego zadania.\nKopie, które już są na tym hoście, ZOSTAJĄ." \
               "$(fit $((${#items[@]} / 2 + 4)))" "$W" "$((${#items[@]} / 2))" "${items[@]}" || continue
            run_verb_with_plan "Usuń $WT_OUT z $NAME" "$ZB" remove-source "$NAME" "$WT_OUT" || continue ;;
    esac
done

PROFILE="${CUR_P:-default}"; SRCPROF=""; SRCKEEP=""
step=1
while :; do
    geom
    if [ "$step" -eq 1 ] && [ "$ACTION" = szablon ]; then
        items=()
        while IFS=$'\t' read -r n t; do
            [ -n "$n" ] || continue
            mark="         "; [ "$n" = "$CUR_P" ] && mark="[obecny] "
            items+=("$n" "$(clip_label "$mark$t" $((W - 10)))")
        done <"$TMPD/prof.tsv"
        def="$PROFILE"; awk -F'\t' -v n="$def" '$1==n{f=1} END{exit !f}' "$TMPD/prof.tsv" || def="${items[0]}"
        wt --title "Zmień relację $NAME -- szablon celu" --ok-button "Dalej" --cancel-button "Anuluj" --notags --default-item "$def" \
           --menu "Obecny szablon: $(cur_words)\nSekcje relacji zostaną wygenerowane od nowa z wybranego szablonu\n(retencja, harmonogramy). Dane nie są przenoszone, seed nie jest potrzebny.\nTen sam szablon = odświeżenie (rozrzut minut, retencja źródła per szczebel)." \
           "$(fit $((${#items[@]} / 2 + 5)))" "$W" "$(lhfit $((${#items[@]} / 2)) 4)" "${items[@]}" || { clear 2>/dev/null; echo "edit-relation: przerwane, nic nie zmieniono"; exit 1; }
        PROFILE="$WT_OUT"; step=2; continue
    fi
    if [ "$step" -eq 1 ] && [ "$ACTION" = harm ]; then
        # Ta sama tabela co szablon na F5 (sposób, wszystkie szczeble, liczby, zamrażanie),
        # startuje z obecnego szablonu relacji; wynik = ukryty szablon relacja-<NAZWA>.
        base="${CUR_P:-default}"
        clear 2>/dev/null
        ZFS_BACKUP="$ZB" bash "$HERE/tui/template.sh" relation "$base" "$TMPD/rargs" "Harmonogram kopii i retencja -- $NAME" \
            || { clear 2>/dev/null; echo "edit-relation: przerwane, nic nie zmieniono"; exit 1; }
        mapfile -t RARGS <"$TMPD/rargs"
        if [ "${#RARGS[@]}" -eq 0 ] && [ "$base" = "$HNAME" ]; then
            PROFILE="$HNAME"          # nic nie zmienione w tabeli -- szablon relacji zostaje
        else
            HFILE="$(head -1 "$TMPD/hfile.txt" 2>/dev/null)"
            if [ -n "$HFILE" ] && [ -z "$HBACKUP" ] && [ -f "$HFILE" ]; then
                HBACKUP="$TMPD/hidden.bak"; cp -p "$HFILE" "$HBACKUP"
            fi
            info "Harmonogram kopii i retencja" "Zapisuję ustawienia relacji..."
            if ! out=$("$ZB" save-profile "--from=$base" "--as=$HNAME" --hidden --force ${RARGS[@]+"${RARGS[@]}"} "--description=Własne ustawienia relacji $NAME" 2>&1); then
                wt --title "Czasownik odmówił -- nic nie zmieniono" --msgbox "$(printf '%s' "$out" | grep -E 'FATAL' | tail -1 | sed 's/^FATAL: //' | fold -s -w $((W - 6)))" 14 "$W"
                continue
            fi
            HIDDEN_DIRTY=1
            load_lists
            [ -n "$HFILE" ] || HFILE="$(head -1 "$TMPD/hfile.txt" 2>/dev/null)"
            PROFILE="$HNAME"
        fi
        step=2; continue
    fi
    if [ "$step" -eq 2 ]; then
        # RETENCJA ŹRÓDŁA: to samo okno-tabela co w kreatorze (uwaga 10).
        src_prefill
        SRC_TITLE="Zmień relację $NAME -- jak długo trzymać u źródła ($HOST)?"
        source_retention_editor || { step=1; continue; }
    fi
    ARGV=("$ZB" edit-relation "$NAME" "--profile=$PROFILE" "--source-profile=$SRCPROF")
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
    if [ -s "$TMPD/rargs.plan" ] && [ "$PROFILE" = "$HNAME" ]; then
        { echo; echo "Zmiany w tabeli szczebli:"; cat "$TMPD/rargs.plan"; } >>"$TMPD/plan2.txt"
    fi
    echo >>"$TMPD/plan2.txt"
    echo "Komenda:  $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes" >>"$TMPD/plan2.txt"
    yesno_text "$TMPD/plan2.txt" "Zmień relację $NAME -- plan" "WYKONAJ" "Wstecz" --defaultno || { step=1; continue; }
    clear 2>/dev/null
    echo "\$ $(for a in "${ARGV[@]}"; do printf '%s ' "$(shq "$a")"; done)--yes"; echo
    "${ARGV[@]}" --yes 2>&1 | tee "$TMPD/run.log"; RC=${PIPESTATUS[0]}
    if [ -n "${ZFS_TUI_LOG:-}" ]; then
        { cat "$TMPD/run.log"; echo "rc=$RC"; } >>"$ZFS_TUI_LOG" 2>/dev/null || :
    fi
    [ "$RC" -eq 0 ] && DONE=1
    echo
    if [ "$RC" -eq 0 ]; then echo "=== GOTOWE: relacja '$NAME' zmieniona (rc=$RC). Enter = dalej"
    else echo "=== NIE UDAŁO SIĘ (rc=$RC) -- nic nie zainstalowano; powód w linii FATAL powyżej. Enter = dalej"; fi
    [ -t 0 ] && read -r _
    exit "$RC"
done
