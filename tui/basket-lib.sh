# basket-lib.sh -- KOSZYK MIEJSC: wybór datasetów wspólny dla kreatorów (dołączany
# przez tui/new-relation.sh i tui/replica.sh; nie uruchamiać samodzielnie).
#
# Model (właściciel 2026-09-18, zmierzony na pve10<-pve11): pozycja koszyka to MIEJSCE
# -- kopiowane jest ono i wszystko, co pod nim JEST i co POWSTANIE. Dodanie miejsca nie
# zadaje pytań; wyjątki (tylko dla tego, co już istnieje) to osobna akcja; -R/-r to
# "jak", nie "co". Wydzielone z new-relation.sh 2026-10-09 (uwaga 13: replika miała
# własną, płaską listę kratek -- "Masz gotowy ekran wybierający datasety przy tworzeniu
# relacji. Dlaczego nie zrobisz tego identycznie?").
#
# Wołający daje: wt-lib.sh (wt, geom, fit, info, clip_label; H W LH), TMPD, PY,
# title <nr> <tekst> (nagłówek okna; koszyk pyta o krok 4), HOST (nazwa w tekstach),
# RECURSION (flat|atomic). BASKET_NO_MODE=1 chowa pozycję "Sposób" (zawsze -R).
# Stan: T_NAME/T_KIDS/T_LABEL (drzewo), B_ROOT/B_EXCL (koszyk; pominięte po jednym w linii).
T_NAME=(); T_KIDS=(); T_LABEL=()
B_ROOT=(); B_EXCL=()

# basket_tree_from_json <list-datasets --json> -> T_*[] (+ $TMPD/own.tsv: migawki spoza
# rodzin Proxmoksa na dataset, gdy JSON je ma). rc 1 = brak datasetów (powód w $TMPD/ds.err).
basket_tree_from_json() {
    "$PY" - "$1" "$TMPD/own.tsv" <<'PYEOF' | tr -d '\r' >"$TMPD/tree.tsv"
import sys, json
ds = json.load(open(sys.argv[1], encoding="utf-8")).get("datasets") or []
names = [d.get("name", "") for d in ds]
# Migawki spoza rodzin Proxmoksa, na dataset (U8: krok 6 przy synchro).
with open(sys.argv[2], "w", encoding="utf-8", newline="\n") as of:
    for d in ds:
        of.write("%s\t%d\n" % (d.get("name", ""), int(d.get("own_snapshots") or 0)))
def human(n):
    n = float(n or 0)
    for u in ("B", "K", "M", "G", "T", "P"):
        if n < 1024 or u == "P":
            return ("%d%s" % (n, u)) if u == "B" or n >= 100 else ("%.1f%s" % (n, u))
        n /= 1024.0
def kids_words(k):
    return "%d pod nim" % k
rows = []
for d in ds:
    n = d.get("name", ""); depth = n.count("/")
    label = ("  " * depth) + (n if depth == 0 else n.rsplit("/", 1)[1])
    kids = sum(1 for x in names if x.startswith(n + "/"))
    rows.append((n, kids, label, human(d.get("used")), "zvol" if d.get("type") == "volume" else ""))
wl = max([len(r[2]) for r in rows] + [10])
for n, kids, label, used, typ in rows:
    print("%s\t%d\t%s  %7s  %-4s  %s" % (n, kids, label.ljust(wl), used, typ, kids_words(kids) if kids else ""))
PYEOF
    T_NAME=(); T_KIDS=(); T_LABEL=()
    local n k l
    while IFS=$'\t' read -r n k l; do
        [ -n "$n" ] || continue
        T_NAME+=("$n"); T_KIDS+=("$k"); T_LABEL+=("$l")
    done <"$TMPD/tree.tsv"
    [ "${#T_NAME[@]}" -gt 0 ] || { echo "źródło nie ma żadnego datasetu" >"$TMPD/ds.err"; return 1; }
    return 0
}

kids_count() { local i; for i in "${!T_NAME[@]}"; do [ "${T_NAME[$i]}" = "$1" ] && { echo "${T_KIDS[$i]}"; return; }; done; echo 0; }
covered() {     # <nazwa> -> 0, gdy koszyk już ją obejmuje (jest korzeniem albo leży pod korzeniem)
    local r; for r in ${B_ROOT[@]+"${B_ROOT[@]}"}; do case "$1" in "$r"|"$r"/*) return 0 ;; esac; done; return 1
}
basket_del() {  # <indeks>
    local i nr=() ne=()
    for i in "${!B_ROOT[@]}"; do [ "$i" = "$1" ] && continue; nr+=("${B_ROOT[$i]}"); ne+=("${B_EXCL[$i]}"); done
    B_ROOT=(${nr[@]+"${nr[@]}"}); B_EXCL=(${ne[@]+"${ne[@]}"})
}
resolve_under() {   # <korzeń> -> 0 = wolno dodać; pozycje POD nim wypadają po zgodzie
    local i under=() txt=""
    for i in "${!B_ROOT[@]}"; do case "${B_ROOT[$i]}" in "$1"/*) under+=("$i"); txt="$txt  ${B_ROOT[$i]}\n" ;; esac; done
    [ "${#under[@]}" -eq 0 ] && return 0
    geom
    wt --title "$1 obejmuje to, co już wybrane" --yes-button "Zastąp" --no-button "Zostaw" \
       --yesno "W koszyku są już pozycje leżące pod $1:\n\n$txt\nCała gałąź $1 je zawiera. Zastąpić je jedną pozycją $1?" "$(fit $((${#under[@]} + 6)))" "$W" || return 1
    for ((i=${#under[@]}-1; i>=0; i--)); do basket_del "${under[$i]}"; done
    return 0
}
describe() {    # <indeks> -> jedno zdanie o pozycji koszyka
    local r="${B_ROOT[$1]}" e="${B_EXCL[$1]}" k short x
    k="$(kids_count "$r")"; short=""
    while IFS= read -r x; do [ -n "$x" ] && short="$short${short:+, }${x#"$r"/}"; done <<<"$e"
    if [ "$k" -eq 0 ]; then echo "dziś nic pod nim; nowe skopiują się same"
    elif [ -z "$short" ]; then echo "dziś $k pod nim; nowe skopiują się same"
    else echo "dziś $k pod nim; BEZ: $short"; fi
}

pick_one() {    # -> PICK ; 1 = wstecz
    local items=() i
    for i in "${!T_NAME[@]}"; do
        covered "${T_NAME[$i]}" && continue
        items+=("${T_NAME[$i]}" "${T_LABEL[$i]}")
    done
    geom
    if [ "${#items[@]}" -eq 0 ]; then
        wt --title "Nie ma czego dodać" --msgbox "Koszyk obejmuje już wszystkie datasety z $HOST." 8 "$W"; return 1
    fi
    wt --title "$(title 4 "Które miejsce z $HOST kopiować?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --menu "Wybierz MIEJSCE. Kopiowane będzie ono i wszystko, co pod nim jest\nalbo POWSTANIE (np. rpool/data na czystym Proxmoxie)." "$H" "$W" "$LH" \
       "${items[@]}" || return 1
    PICK="$WT_OUT"; [ -n "$PICK" ]
}
add_flow() {    # <nazwa> -> 0 = dodano. Żadnych pytań: każde miejsce znaczy to samo.
    resolve_under "$1" || return 1
    B_ROOT+=("$1"); B_EXCL+=(""); return 0
}
with_kids() {   # -> WK[] indeksy pozycji koszyka, pod którymi dziś coś leży
    local i; WK=()
    for i in "${!B_ROOT[@]}"; do [ "$(kids_count "${B_ROOT[$i]}")" -gt 0 ] && WK+=("$i"); done
    return 0
}
except_flow() { # wyjątki dla jednej pozycji; stan obecny wraca jako odznaczone
    local idx items=() i n x st name ex=() all=()
    with_kids
    if [ "${#WK[@]}" -eq 1 ]; then idx="${WK[0]}"
    else
        for i in "${WK[@]}"; do items+=("$i" "${B_ROOT[$i]}  -- $(describe "$i")"); done
        geom
        wt --title "$(title 4 'Wyjątki -- dla którego miejsca?')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
           --menu "Wyjątki można wskazać tylko tam, gdzie pod miejscem coś już leży." "$(fit $((${#WK[@]} + 3)))" "$W" "${#WK[@]}" \
           "${items[@]}" || return 0
        idx="$WT_OUT"
    fi
    name="${B_ROOT[$idx]}"; items=()
    for i in "${!T_NAME[@]}"; do
        n="${T_NAME[$i]}"
        case "$n" in "$name"/*) ;; *) continue ;; esac
        st=ON
        while IFS= read -r x; do [ -n "$x" ] && case "$n" in "$x"|"$x"/*) st=OFF ;; esac; done <<<"${B_EXCL[$idx]}"
        items+=("$n" "${T_LABEL[$i]}" "$st"); all+=("$n")
    done
    geom
    wt --title "$(title 4 "$name -- czego NIE kopiować?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "Zaznaczone = kopiowane. ODZNACZ spacją to, co ma być pomijane\n(razem z tym, co pod nim). Przyszłych datasetów pominąć się nie da." "$H" "$W" "$LH" \
       "${items[@]}" || return 0
    for n in "${all[@]}"; do
        printf '%s\n' "$WT_OUT" | grep -qxF -- "$n" && continue
        st=0; for i in ${ex[@]+"${ex[@]}"}; do case "$n" in "$i"/*) st=1 ;; esac; done
        [ "$st" -eq 1 ] || ex+=("$n")       # pominięty przodek już obejmuje potomka
    done
    B_EXCL[$idx]="$(printf '%s\n' ${ex[@]+"${ex[@]}"})"
    return 0
}
remove_flow() {
    local items=() i n
    for i in "${!B_ROOT[@]}"; do items+=("$i" "${B_ROOT[$i]}  -- $(describe "$i")" OFF); done
    geom
    wt --title "$(title 4 'Usuń z koszyka')" --ok-button "Usuń zaznaczone" --cancel-button "Wstecz" --notags --separate-output \
       --checklist "Zaznacz spacją pozycje do usunięcia." "$(fit $((${#B_ROOT[@]} + 3)))" "$W" "${#B_ROOT[@]}" \
       "${items[@]}" || return 0
    for n in $(printf '%s\n' "$WT_OUT" | sort -rn); do basket_del "$n"; done
}
is_excluded() { # <indeks> <nazwa> -> 0, gdy nazwa jest pomijana (sama albo przez przodka)
    local x
    while IFS= read -r x; do [ -n "$x" ] && case "$2" in "$x"|"$x"/*) return 0 ;; esac; done <<<"${B_EXCL[$1]}"
    return 1
}
entry_lines() { # <indeks> <ile nazw kopiowanych pokazać> -> 2-3 wiersze o pozycji koszyka
    # Zwarty zapis: na terminalu 24-wierszowym lista "po jednym w wierszu" chowała pomijane
    # pod "... i jeszcze 2". POMIJANE są więc ZAWSZE wypisane w całości; skraca się tylko
    # listę kopiowanych.
    local r="${B_ROOT[$1]}" cap="$2" i n kept="" nk=0 more=0 excl=""
    for i in "${!T_NAME[@]}"; do
        n="${T_NAME[$i]}"; case "$n" in "$r"/*) ;; *) continue ;; esac
        if is_excluded "$1" "$n"; then
            # potomek pominiętego przodka nie wymaga własnej wzmianki
            [ "${n%/*}" != "$r" ] && is_excluded "$1" "${n%/*}" && continue
            excl="$excl${excl:+, }${n#"$r"/}"
        elif [ "$nk" -lt "$cap" ]; then kept="$kept${kept:+, }${n#"$r"/}"; nk=$((nk + 1))
        else more=$((more + 1)); fi
    done
    printf '  %s   (+ wszystko, co pod nim POWSTANIE)\n' "$r"
    if [ -z "$kept" ] && [ -z "$excl" ]; then printf '      dziś nic pod nim\n'
    else
        [ -n "$kept" ] && printf '      dziś pod nim: %s%s\n' "$kept" "$( [ "$more" -gt 0 ] && echo " … i $more innych")"
        [ -z "$kept" ] && printf '      dziś pod nim: nic, co byłoby kopiowane\n'
    fi
    [ -n "$excl" ] && printf '      POMIJANE: %s\n' "$excl"
    return 0
}
mode_words() { [ "$RECURSION" = atomic ] && echo "cała gałąź atomowo (-r)" || echo "każdy dataset osobno (-R)"; }
any_excl() { local i; for i in "${!B_ROOT[@]}"; do [ -n "${B_EXCL[$i]}" ] && return 0; done; return 1; }
mode_flow() {   # -R/-r: JEDNO na relację; atomowo wyklucza wyjątki, więc pyta, zanim je zdejmie
    geom
    local f=OFF a=OFF i; [ "$RECURSION" = atomic ] && a=ON || f=ON
    wt --title "$(title 4 'Sposób kopiowania')" --ok-button "Dalej" --cancel-button "Wstecz" --notags \
       --radiolist "To ustawienie jest JEDNO na całą relację.\n\nOsobno: każdy dataset ma własne migawki; awaria jednego nie zatrzymuje\nreszty. Atomowo: jedna migawka całej gałęzi w tej samej chwili, ale\nnie da się wtedy nic pominąć ani sprzątać migawek u źródła." "$(fit 10)" "$W" 2 \
       flat   "Każdy dataset osobno (-R)  -- zalecane" "$f" \
       atomic "Cała gałąź atomowo (-r)" "$a" || return 0
    [ -n "$WT_OUT" ] || return 0
    if [ "$WT_OUT" = atomic ] && any_excl; then
        wt --title "Atomowo nie pozwala pomijać" --yes-button "Zdejmij wyjątki" --no-button "Wstecz" \
           --yesno "W koszyku są wyjątki, a przy kopiowaniu atomowym nie da się nic pominąć.\n\nZdjąć wszystkie wyjątki i przejść na atomowo?" 11 "$W" || return 0
        for i in "${!B_ROOT[@]}"; do B_EXCL[$i]=""; done
    fi
    RECURSION="$WT_OUT"
}
basket_window() {   # -> ACT = add | exc | mode | del | next ; 1 = wstecz
    local txt="" i lines=0 avail cap menu=() block n
    geom
    avail=$((H - 13)); [ "$avail" -lt 4 ] && avail=4
    cap=6; [ "${#B_ROOT[@]}" -gt 2 ] && cap=3
    for i in "${!B_ROOT[@]}"; do
        block="$(entry_lines "$i" "$cap")"; n=$(printf '%s\n' "$block" | fold -s -w $((W - 4)) | grep -c '')
        if [ $((lines + n)) -gt "$avail" ] && [ "$lines" -gt 0 ]; then
            txt="$txt  … i jeszcze miejsc: $((${#B_ROOT[@]} - i))\n"; lines=$((lines + 1)); break
        fi
        txt="$txt${block//$'\n'/\\n}\n"; lines=$((lines + n))
    done
    with_kids
    menu=(add "Dodaj miejsce…")
    [ "${#WK[@]}" -gt 0 ] && menu+=(exc "Wyjątki…   (czego pod miejscem NIE kopiować)")
    [ "${MODE:-}" = local ] || [ "${BASKET_NO_MODE:-0}" = 1 ] || menu+=(mode "Sposób: $(mode_words) -- zmień…")
    menu+=(del "Usuń pozycję…" next "Dalej")
    wt --title "$(title 4 "Co kopiować z $HOST?")" --ok-button "Dalej" --cancel-button "Wstecz" --notags --default-item next \
       --menu "Kopiowane będzie:\n\n$txt" "$(fit $((lines + 8)))" "$W" "$((${#menu[@]} / 2))" \
       "${menu[@]}" || return 1
    ACT="$WT_OUT"
}
# basket_step -> 0 = Dalej z niepustym koszykiem, 1 = Wstecz. Pusty koszyk: od razu lista.
basket_step() {
    while :; do
        if [ "${#B_ROOT[@]}" -eq 0 ]; then     # pusty koszyk: od razu lista, bez pustego okna
            pick_one || return 1
            add_flow "$PICK"
            continue
        fi
        basket_window || return 1
        case "$ACT" in
            add)  if pick_one; then add_flow "$PICK"; fi ;;
            exc)  if [ "$RECURSION" = atomic ]; then
                      geom
                      wt --title "Przy atomowo nie da się pomijać" --msgbox "Sposób kopiowania to teraz: $(mode_words).\nJedna migawka całej gałęzi nie ma gdzie niczego odfiltrować.\n\nŻeby wskazać wyjątki, zmień najpierw Sposób na 'każdy dataset osobno'." 12 "$W"
                  else except_flow; fi ;;
            mode) mode_flow ;;
            del)  remove_flow ;;
            next) return 0 ;;
        esac
    done
}
