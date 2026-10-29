#!/bin/bash
# wt-lib.sh -- wspolne klocki okien whiptail dla kreatora (new-relation.sh) i dialogu
# usuwania (delete-relation.sh). Dolaczane przez `.`, nie uruchamiane.
#
# Zasady, ktore tu mieszkaja, bo dotycza KAZDEGO okna (zmierzone jazda po pty na pve10):
#   - rozmiar z terminala przy kazdym oknie; okno wieksze od ekranu whiptail ucina bez slowa;
#   - NEWT_COLORS z widocznym biezacym wierszem; polskie znaki wymagaja UTF-8;
#   - okno z --scrolltext trzyma fokus na tekscie i Enter nic nie robi bez Taba, wiec
#     tekst ma sie miescic (wiersze liczone PO zawinieciu);
#   - lista nie moze byc wyzsza niz miejsce po opisie, inaczej opis znika.
# Wolajacy ustawia WT_BACKTITLE przed pierwszym oknem.

WT="${WHIPTAIL:-whiptail}"
# Interpreter wybierany przez URUCHOMIENIE, nie przez `command -v`: nazwa, ktora
# sie rozwiazuje, nie musi dzialac (alias sklepowy na Windows).
PY=""
for c in ${PYTHON:+"$PYTHON"} python3 python; do "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }; done

command -v "$WT" >/dev/null 2>&1 || { echo "okna: brak '$WT' (pakiet whiptail)" >&2; exit 1; }
[ -n "$PY" ] || { echo "okna: brak dzialajacego python3" >&2; exit 1; }

# Polskie znaki: newt liczy szerokości wg locale. Bez UTF-8 ramki się rozjeżdżają.
case "$(locale charmap 2>/dev/null)" in UTF-8) ;; *) export LC_ALL=C.UTF-8 ;; esac
export PYTHONIOENCODING=utf-8 PYTHONDONTWRITEBYTECODE=1    # import tui/zfs-tui.py nie ma zostawiac __pycache__ w checkoucie hosta
export NEWT_COLORS="${NEWT_COLORS:-root=,blue window=black,white border=black,white title=black,white listbox=black,white actlistbox=white,black sellistbox=black,white actsellistbox=white,black checkbox=black,white actcheckbox=white,black button=black,cyan actbutton=white,red textbox=black,white entry=black,white label=black,white}"


# JĘZYK OKIEN (jak w zfs-tui.py): ZFS_TUI_LANG z GUI, inaczej [gui] language w settings.ini,
# domyślnie angielski (jak zfs-tui.py). T <tekst polski> [argumenty printf] -> tekst w tym języku; bez wpisu w
# tui/lang/<język>.json -- polski. Katalog to DANE: czytany jako pary NUL-owe, nic się nie
# wykonuje; szablon z %s dostaje argumenty przez printf, nigdy przez eval.
if [ -z "${ZFS_TUI_LANG:-}" ]; then
    ZFS_TUI_LANG="$(awk -F= 'BEGIN{s="engine"} {sub(/#.*/,"")} /^[ \t]*\[[A-Za-z0-9_]+\][ \t]*$/{s=$0; gsub(/[][ \t]/,"",s); next}
        s=="gui" { k=$1; gsub(/[ \t]/,"",k); if (k=="language") { v=$2; gsub(/[ \t]/,"",v); print v; exit } }' \
        "${SETTINGS_FILE:-/etc/zfs-snapshot-all/settings.ini}" 2>/dev/null)"
fi
case "${ZFS_TUI_LANG:-}" in pl|en) ;; *) ZFS_TUI_LANG=en ;; esac
export ZFS_TUI_LANG
declare -A TCAT=()
_tcat="$(dirname "${BASH_SOURCE[0]}")/lang/$ZFS_TUI_LANG.json"
if [ "$ZFS_TUI_LANG" != pl ] && [ -r "$_tcat" ]; then
    while IFS= read -r -d '' _tk && IFS= read -r -d '' _tv; do TCAT["$_tk"]="$_tv"; done < <("$PY" -c '
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
sys.stdout.buffer.write(b"".join(k.encode("utf-8") + b"\0" + v.encode("utf-8") + b"\0"
                                 for k, v in d.items() if k and "\0" not in k + v))' "$_tcat")
fi
# Python wklejony w skrypt (heredoc) tłumaczy tym samym katalogiem: ścieżka w ZFS_TUI_CAT,
# czytana przez json.load (dane, nie kod); pusta = polski.
ZFS_TUI_CAT=""
[ "$ZFS_TUI_LANG" != pl ] && [ -r "$_tcat" ] && ZFS_TUI_CAT="$(cd "$(dirname "$_tcat")" && pwd)/$(basename "$_tcat")"
export ZFS_TUI_CAT
unset _tcat _tk _tv
T() {   # <tekst polski / szablon printf> [argumenty]
    local k="$1" v; shift
    v="${TCAT[$k]-$k}"
    if [ $# -gt 0 ]; then printf -- "$v" "$@"; else printf '%s' "$v"; fi
}
# Tv <tekst, jak stoi w kodzie, ze zmiennymi NIEROZWINIĘTYMI> [<znacznik> <wartość>]...
# Klucz katalogu to tekst z kodu razem z nazwami zmiennych ($HOST, ${NAME}, $(hostport)), więc
# podaje się go w apostrofach, a wartości osobno: Tv 'Sprawdzam $(hostport) jako root' '$(hostport)' "$(hostport)".
# Po tłumaczeniu każdy znacznik jest zamieniany na wartość -- zwykła zamiana napisów, bez eval;
# wartość (dane z hosta) nigdy nie jest interpretowana.
Tv() {
    local v="${TCAT[$1]-$1}"; shift
    while [ $# -ge 2 ]; do v="${v//"$1"/"$2"}"; shift 2; done
    printf '%s' "$v"
}

geom() {   # H W LH z bieżącego terminala
    local l c
    l=$(tput lines 2>/dev/null) || l=24; c=$(tput cols 2>/dev/null) || c=80
    case "$l" in ''|*[!0-9]*) l=24 ;; esac; case "$c" in ''|*[!0-9]*) c=80 ;; esac
    H=$((l - 2)); W=$((c - 4)); [ "$W" -gt 100 ] && W=100; LH=$((H - 9))
    [ "$LH" -lt 3 ] && LH=3
    return 0
}
fit() {    # <wiersze tekstu+listy> -> wysokość okna, nie większa niż ekran
    local h=$(($1 + 7)); [ "$h" -gt "$H" ] && h=$H; echo "$h"
}
wt() {     # whiptail z odpowiedzią w WT_OUT; rc: 0 = OK, inne = wstecz
    WT_OUT=$("$WT" --backtitle "${WT_BACKTITLE:-zfs-snapshot-all -- $(hostname)}" "$@" 3>&1 1>&2 2>&3)
}
# INFOBOX MUSI ZOSTAĆ NA EKRANIE (kampania 2026-10-22, pve10): przy TERM=xterm (PuTTY, tmux)
# whiptail rysuje na DRUGIM ekranie terminala (smcup) i przy wyjściu go zdejmuje -- infobox
# znikał w tej samej chwili, a operator patrzył na czarny ekran. Opis "linux" nie przełącza
# ekranu, a ma te same kolory; ramki newt w UTF-8 rysuje i tak znakami Unicode.
INFO_TERM="${WT_INFO_TERM:-linux}"
info() {   # <tytuł> <tekst> -- okno bez przycisków na czas czekania
    TERM="$INFO_TERM" "$WT" --backtitle "${WT_BACKTITLE:-zfs-snapshot-all -- $(hostname)}" --title "$1" --infobox "$2" 7 "$W"
}
lhfit() {  # <pozycji> <wierszy tekstu> -> wysokość listy, która zostawia miejsce na tekst
    local n="$1" max=$((H - 7 - $2)); [ "$max" -lt 3 ] && max=3; [ "$n" -gt "$max" ] && n=$max; echo "$n"
}
# U67 (owner 2026-10-21): an okno odmowy shows WHY, not only the verb's closing FATAL line --
# the reason a verb prints above it ("!!! gen-cron.sh refused ...", "... error: ...") is
# what tells the operator what to change. Lines with !!!, 'error:' and FATAL, prefixes
# stripped, each once, the last six.
verb_refusal() {   # <plik z wyjściem czasownika> -> przyczyna odmowy do okna
    grep -E '^!!! |error: |^FATAL: ' "$1" 2>/dev/null \
        | sed -e 's/^!!! //' -e 's/^[[:space:]]*//' -e 's/^FATAL: //' | awk '!seen[$0]++' | tail -6
}
# OKNO POSTĘPU (U66/U64, właściciel 2026-10-21: "czarny ekran ponad 15 sekund i dopiero powrót"):
# polecenie biegnie w tle z wyjściem do dziennika, okno pokazuje, ile już trwa. Właściciel
# 2026-10-26 (pve2): linie dziennika w oknie migały przy każdym odświeżeniu -- okno mówi tylko
# "trwa" i gdzie jest dziennik (okno raz, sekundy w dolnym wierszu -- niżej); wyjście czyta result_box. Bez terminala dla polecenia (stdin z /dev/null): pytanie w terminalu
# kończy się odmową, nie zawieszeniem za oknem. Ctrl-C przerywa polecenie.
run_progress() {   # <tytuł> <dziennik> <polecenie...> -> rc polecenia; dziennik dopisywany
    local t="$1" log="$2" pid rc=0 s0=$SECONDS i
    shift 2
    case "$1" in */*) { printf '$'; printf ' %s' "$@"; printf '\n\n'; } >>"$log" ;; esac   # nagłówek dla programu, nie dla funkcji
    "$@" >>"$log" 2>&1 </dev/null &
    pid=$!
    trap 'kill "$pid" 2>/dev/null' INT
    # OKNO RAZ, licznik w dolnym wierszu (wlasciciel 2026-10-29, zrzut "Zmień relację pve9b:
    # wykonuję -- trwa 16 s": "miga ... rzęzi"). Kazde wywolanie whiptail zaczyna od wyczyszczenia
    # ekranu (ESC[H ESC[J, zmierzone na pve10), a petla rysowala okno co 2 s. Teraz okno jest
    # rysowane raz, a sekundy co sekunde dopisuje sie w ostatnim wierszu ekranu -- jego miejsce
    # jest znane (tput lines), polozenia ramki whiptaila nie trzeba zgadywac.
    geom
    TERM="$INFO_TERM" "$WT" --backtitle "${WT_BACKTITLE:-zfs-snapshot-all -- $(hostname)}" --title "$t" \
          --infobox "$(T 'Trwa wykonywanie, proszę czekać.\n\nKomunikaty poleceń idą do dziennika:\n  %s\n\nCtrl-C przerywa.' "$log")" 12 "$W"
    local rows; rows=$(tput lines 2>/dev/null) || rows=24
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    while kill -0 "$pid" 2>/dev/null; do
        # tylko na terminalu: biale na niebieskim (tlo whiptaila), reszta wiersza czyszczona tym tlem
        [ -t 1 ] && printf '\033[%d;1H\033[1;37;44m%s\033[K\033[m' "$rows" "$(T '  trwa %d s' "$((SECONDS - s0))")"
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    done
    wait "$pid" || rc=$?
    trap - INT
    return "$rc"
}
# Wynik po run_progress: GOTOWE krótko; odmowa = przyczyna (verb_refusal) i koniec dziennika.
result_box() {   # <tytuł> <rc> <dziennik> <tekst przy rc=0> [tekst przy rc!=0]
    local t="$1" rc="$2" log="$3" okt="$4" bad="${5:-$(T 'Nie udało się.')}"
    geom
    if [ "$rc" -eq 0 ]; then
        # GOTOWE TYLKO PRZY BLEDZIE (wlasciciel 2026-10-29: "absolutne minimum: Na pewno? i
        # koniec"). Jednozdaniowy sukces idzie na linie komunikatu GUI (wt_end), bez okna;
        # okno zostaje, gdy tekst ma dalsze linie -- to sa rzeczy do zrobienia recznie.
        if [ "$(printf '%b\n' "$okt" | grep -c .)" -le 1 ]; then
            wt_end "$(printf '%b' "$okt")"
            return 0
        fi
        local l; l=$(printf '%b
' "$okt" | fold -s -w $((W - 4)) | grep -c '')
        l=$((l + 6)); [ "$l" -gt "$H" ] && l=$H
        wt --title "$t" --msgbox "$okt" "$l" "$W"
        return 0
    fi
    { printf '%s  (rc=%s)\n\n' "$bad" "$rc"
      if [ -n "$(verb_refusal "$log")" ]; then printf '%s\n' "$(T 'Powód:')"; verb_refusal "$log" | sed 's/^/  /'; printf '\n'; fi
      printf '%s\n' "$(T 'Koniec dziennika:')"; tail -n 15 "$log" | sed 's/^/  /'
    } >"$log.view"
    textbox_read "$t" "$log.view" "$(T Zamknij)"
    return 0
}
clip_label() {  # <tekst> <max znaków> -> tekst, ucięty z '…' gdy dłuższy (pozycja listy nie rozsadzi ramki)
    local t="$1" m="$2"
    [ "$m" -lt 8 ] && m=8
    if [ "${#t}" -gt "$m" ]; then printf '%s…' "${t:0:$((m - 1))}"; else printf '%s' "$t"; fi
}
# OKNO TEKSTU DO CZYTANIA (przejście na żywo pve10, 2026-10-23): whiptail --textbox BEZ
# --scrolltext nie przewija -- strzałki, PgDn i Tab nic nie robiły, plan dłuższy niż ekran
# był ucięty na pierwszej stronie. Z --scrolltext strzałki przewijają, ale Enter działa
# dopiero po Tab na przycisku (Esc = wstecz) -- zmierzone. Krótki tekst: zwykłe okno, Enter
# zamyka; długi: przewijanie i te klawisze w tytule (na ramce).
textbox_read() {   # <tytuł> <plik> [przycisk, domyślnie Dalej] -> rc whiptail (Esc = 1/255)
    local t="$1" f="$2" b="${3:-$(T Dalej)}" lines
    geom
    lines=$(fold -s -w $((W - 4)) "$f" | grep -c '')
    if [ "$lines" -le $((H - 7)) ]; then
        wt --title "$t" --ok-button "$b" --textbox "$f" "$H" "$W"
    else
        wt --title "$(Tv '$t  [strzałki przewijają, Tab -> $b, Esc wraca]' '$t' "$t" '$b' "$b")" --ok-button "$b" --scrolltext --textbox "$f" "$H" "$W"
    fi
}
yesno_text() {  # <plik> <tytuł> <tak> <nie> [--defaultno] -> yesno; przewijanie TYLKO gdy się nie mieści
    # W oknie z --scrolltext fokus startuje na tekście i Enter nic nie robi, dopóki nie
    # przejdziesz Tabem na przyciski (zmierzone jazdą po pty). Więc: bez przewijania,
    # kiedy tylko się da, a kiedy nie -- tekst osobno, pytanie osobno (niżej).
    local f="$1" t="$2" y="$3" n="$4" extra="${5:-}" lines
    geom
    lines=$(fold -s -w $((W - 4)) "$f" | grep -c '')      # whiptail zawija; licz wiersze PO zawinięciu
    if [ "$lines" -le $((H - 6)) ]; then
        wt --title "$t" --yes-button "$y" --no-button "$n" $extra --yesno "$(cat "$f")" "$(fit $((lines + 1)))" "$W"
    else
        # Kampania 2026-10-22 (pve10, plan kopii lokalnej): w oknie z --scrolltext Enter nie
        # robił nic, admin naciskał go i czekał. Długi tekst idzie najpierw do czytania
        # (textbox_read: przewijanie, Tab -> Dalej na ramce; bez --scrolltext okno nie przewija
        # wcale -- 2026-10-23), potem krótkie pytanie z tymi samymi przyciskami -- jak plan w
        # zmianie relacji. Esc w oknie tekstu = "nie".
        textbox_read "$t" "$f" || return 1
        wt --title "$t" --yes-button "$y" --no-button "$n" $extra \
           --yesno "$(Tv 'Plan był w poprzednim oknie (wierszy: $lines). $y?' '$lines' "$lines" '$y' "$y")" 8 "$W"
    fi
}
# EDYTOR LISTY -- jeden wzór okna dla każdego "dodaj / usuń pozycje" (decyzja właściciela
# 2026-10-11, W3/W13/W10). Checklisty są do tego zakazane: Enter potwierdza okno bez
# przełączania (przełącza tylko spacja), a rodzic daje się odznaczyć przy zaznaczonych dzieciach.
# Wołający wypełnia globalną tablicę LE_ITEMS przed wywołaniem i czyta ją po nim.
# Wywołanie zwrotne <addcb>: rc 0 + LE_NEW = nowa pozycja, rc 1 = wstecz (nic nie dodano).
# rc funkcji: 0 = Gotowe, 1 = Wstecz (LE_ITEMS wraca do stanu z wejścia).
list_editor() {  # <tytuł> <wstęp> <tekst gdy pusto> <etykieta dodaj> <etykieta usuń> <addcb>
    local ttl="$1" intro="$2" empty="$3" addl="$4" dell="$5" addcb="$6"
    local saved=() it text menu=() n i il choice keep=() dup
    for it in ${LE_ITEMS[@]+"${LE_ITEMS[@]}"}; do saved+=("$it"); done
    while :; do
        geom
        n=${#LE_ITEMS[@]}
        il=$(( ${#intro} / (W - 8) + 3 ))
        if [ "$n" -eq 0 ]; then
            text="$intro\n\n$empty"; il=$((il + 1))
        else
            text="$intro\n"
            for it in "${LE_ITEMS[@]}"; do text+="\n  $(clip_label "$it" $((W - 10)))"; done
            il=$((il + n))
        fi
        menu=(__add__ "+ $(clip_label "$addl" $((W - 14)))")
        [ "$n" -gt 0 ] && menu+=(__del__ "− $(clip_label "$dell" $((W - 14)))")
        menu+=(__done__ "$(T Gotowe)")
        wt --title "$ttl" --ok-button "$(T Wybierz)" --cancel-button "$(T Wstecz)" --notags --default-item __done__ \
           --menu "$text" "$(fit $((il + ${#menu[@]} / 2 + 1)))" "$W" "$(lhfit $((${#menu[@]} / 2)) "$il")" \
           "${menu[@]}" || { LE_ITEMS=(${saved[@]+"${saved[@]}"}); return 1; }
        choice="$WT_OUT"
        case "$choice" in
            __done__) return 0 ;;
            __add__)
                LE_NEW=""
                "$addcb" || continue
                dup=0
                for it in ${LE_ITEMS[@]+"${LE_ITEMS[@]}"}; do [ "$it" = "$LE_NEW" ] && dup=1; done
                [ "$dup" -eq 0 ] && LE_ITEMS+=("$LE_NEW")
                ;;
            __del__)
                geom
                menu=()
                for i in "${!LE_ITEMS[@]}"; do menu+=("i:$i" "$(clip_label "${LE_ITEMS[i]}" $((W - 14)))"); done
                wt --title "$ttl" --ok-button "$(T Usuń)" --cancel-button "$(T Wstecz)" --notags \
                   --menu "$(T 'Który usunąć?')" "$(fit $((${#menu[@]} / 2 + 3)))" "$W" "$(lhfit $((${#menu[@]} / 2)) 3)" \
                   "${menu[@]}" || continue
                choice="${WT_OUT#i:}"
                keep=()
                for i in "${!LE_ITEMS[@]}"; do [ "$i" = "$choice" ] || keep+=("${LE_ITEMS[i]}"); done
                LE_ITEMS=(${keep[@]+"${keep[@]}"})
                ;;
        esac
    done
}
# Drugi argument: nazwa relacji z tym hostem -- relacja nazywa się jak host po drugiej
# stronie (właściciel 2026-10-29), więc gdy /etc/hosts milczy, to ona, a nie sam adres.
host_name() {   # <adres|nazwa> [nazwa relacji] -> nazwa z /etc/hosts tego hosta (U111, 2026-10-29); bez DNS
    case "$1" in
        ''|*[!0-9.:]*) printf '%s' "$1" ;;
        *) awk -v a="$1" '{ sub(/#.*/, "") } $1 == a { for (i = 2; i <= NF; i++) { if ($i ~ /^localhost/) continue; if ($i !~ /\./) { print $i; ok = 1; exit } if (f == "") f = $i } }
               END { if (!ok && f != "") { sub(/\..*/, "", f); print f } }' "${ZFS_TUI_HOSTS:-/etc/hosts}" 2>/dev/null | grep . || printf '%s' "${2:-$1}" ;;
    esac
}
plan_words() {   # stdin -> plan bez linii crona i znaczników bloku (okno planu; pełny plan idzie do pliku)
    grep -vE '^[[:space:]]*[-+]?[[:space:]]*(([0-9*/,@-]+|[a-z]+)[[:space:]]+){4}[0-9*/,a-z-]+[[:space:]]+/|^[[:space:]]*[-+]?[[:space:]]*# (BEGIN|END) zfs-backup|^[[:space:]]*[-+]?[[:space:]]*\*/[0-9]+ ' || true
}
shq() {   # argument tak, jak wpisałby go człowiek: apostrofy tylko tam, gdzie trzeba
    case "$1" in *[!A-Za-z0-9_./:=,@%+-]*) printf "'%s'" "$1" ;; *) printf '%s' "$1" ;; esac
}

# KARTA RELACJI (U25, właściciel 2026-10-20: "gdy tworzę relację i modyfikuję -- okno
# ma być to samo"). Jedno okno dla kreatora (Ins) i zmiany (e): lista pól z wartościami,
# pod kreską akcje. Pole stałe (zmiana relacji: rodzaj, cel, nazwa, konto) ma dopisek
# "(stałe)" -- whiptail nie koloruje pojedynczych wierszy, więc "na szaro" = ten dopisek.
# Wejście: CARD_TAGS CARD_NAMES CARD_VALUES CARD_FIXED (1 = stałe), CARD_ACT_TAGS
# CARD_ACT_LABELS. Wybór w WT_OUT; kreska (__sep__) nic nie robi -- woła ją pętla.
card_menu() {   # <tytuł> <tekst> <domyślny tag> <przycisk Wstecz/Wyjdź>; rc 1 = ten przycisk
    local t="$1" x="$2" d="$3" c="$4" i v lb w items=()
    geom
    w=$((W - 10))
    local pad=17 nm      # kolumna wartości: najdłuższa nazwa + 2 (U65: "* Retencja źródła" się nie mieściła)
    for nm in "${CARD_NAMES[@]}"; do [ $((${#nm} + 2)) -gt "$pad" ] && pad=$((${#nm} + 2)); done
    for i in "${!CARD_TAGS[@]}"; do
        v="${CARD_VALUES[$i]:-…}"
        # Wyrównanie po ZNAKACH (${#}), nie bajtach: printf %-16s liczy bajty i "Źródło"
        # wypadało z kolumny.
        lb="${CARD_NAMES[$i]}"; while [ "${#lb}" -lt "$pad" ]; do lb="$lb "; done; lb="$lb$v"
        if [ "${CARD_FIXED[$i]:-0}" = 1 ]; then
            items+=("${CARD_TAGS[$i]}" "$(clip_label "$lb" $((w - 10)))  $(T '(stałe)')")
        else
            items+=("${CARD_TAGS[$i]}" "$(clip_label "$lb" "$w")")
        fi
    done
    [ "${#CARD_ACT_TAGS[@]}" -gt 0 ] && items+=(__sep__ "──────────────────────────────────────────")
    for i in "${!CARD_ACT_TAGS[@]}"; do items+=("${CARD_ACT_TAGS[$i]}" "$(clip_label "${CARD_ACT_LABELS[$i]}" "$w")"); done
    wt --title "$t" --ok-button "$(T Wybierz)" --cancel-button "$c" --notags --default-item "$d" \
       --menu "$x" "$(fit $((${#items[@]} / 2 + 5)))" "$W" "$((${#items[@]} / 2))" "${items[@]}"
}

# Ostatnie slowo okna: na terminal i do pliku statusu, ktory GUI pokazuje po powrocie
# w linii komunikatu (zamiast "[rc=1] <linia polecenia>" -- kampania 3, 2026-10-23).
wt_end() {   # <tekst>
    echo "$1"
    [ -n "${ZFS_TUI_STATUS:-}" ] && printf '%s
' "$1" >"$ZFS_TUI_STATUS" 2>/dev/null
    return 0
}

# Jak wt_end, ale okno ZAMYKA SIE BEZ ZMIAN (przerwane, wyjscie bez zapisu): druga linia
# "nochange" mowi GUI, ze danych nie trzeba czytac od nowa -- anulowanie edycji kosztowalo
# 3-6 s pelnego odswiezenia (przejscie GUI pve10, 2026-10-28). Znacznik, nie tekst: tekst
# jest tlumaczony.
wt_end_nochange() {   # <tekst>
    echo "$1"
    [ -n "${ZFS_TUI_STATUS:-}" ] && printf '%s
nochange
' "$1" >"$ZFS_TUI_STATUS" 2>/dev/null
    return 0
}
