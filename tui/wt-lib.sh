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
info() {   # <tytuł> <tekst> -- okno bez przycisków na czas czekania
    "$WT" --backtitle "${WT_BACKTITLE:-zfs-snapshot-all -- $(hostname)}" --title "$1" --infobox "$2" 7 "$W"
}
lhfit() {  # <pozycji> <wierszy tekstu> -> wysokość listy, która zostawia miejsce na tekst
    local n="$1" max=$((H - 7 - $2)); [ "$max" -lt 3 ] && max=3; [ "$n" -gt "$max" ] && n=$max; echo "$n"
}
yesno_text() {  # <plik> <tytuł> <tak> <nie> [--defaultno] -> yesno; przewijanie TYLKO gdy się nie mieści
    # W oknie z --scrolltext fokus startuje na tekście i Enter nic nie robi, dopóki nie
    # przejdziesz Tabem na przyciski (zmierzone jazdą po pty). Więc: bez przewijania,
    # kiedy tylko się da, a kiedy nie -- tytuł mówi o Tabie.
    local f="$1" t="$2" y="$3" n="$4" extra="${5:-}" lines
    geom
    lines=$(fold -s -w $((W - 4)) "$f" | grep -c '')      # whiptail zawija; licz wiersze PO zawinięciu
    if [ "$lines" -le $((H - 6)) ]; then
        wt --title "$t" --yes-button "$y" --no-button "$n" $extra --yesno "$(cat "$f")" "$(fit $((lines + 1)))" "$W"
    else
        wt --title "$t  [strzałki = przewijaj, Tab = przyciski]" --yes-button "$y" --no-button "$n" $extra --scrolltext --yesno "$(cat "$f")" "$H" "$W"
    fi
}
shq() {   # argument tak, jak wpisałby go człowiek: apostrofy tylko tam, gdzie trzeba
    case "$1" in *[!A-Za-z0-9_./:=,@%+-]*) printf "'%s'" "$1" ;; *) printf '%s' "$1" ;; esac
}
