#!/bin/bash
# ============================================================================
# tui -- CZTERY OKNA, SPRAWDZONE BEZ TERMINALA (F5 Monitor zniesiony 2026-09-24)
#
# Owner, 2026-09-09: "zrobic te nieszczesne okna, ogarnac problemy, sprawdzic
# funkcjonalnosc i sensowny wyglad tych okien oraz poprawnosc ich dzialan."
#
# Rysowanie jest funkcja czysta (STAN -> LINIE), a `--render-once --screen X
# --keys ...` drukuje DOKLADNIE to, co narysowalby curses po tej sekwencji
# klawiszy. Ta suita patrzy wiec na to samo, co operator, a petla curses zostala
# osobno przejechana na pve10 przez pty (klawisze F2-F5, Enter, Esc, q; wyjscie
# 0; kolory 31/32/33/36 w strumieniu) -- tego z tej maszyny sie nie da, bo
# plink -batch nie daje terminala.
#
# WEJSCIE POCHODZI Z PRAWDZIWYCH CZASOWNIKOW. test/tui/fixtures/pve10/ to
# doslowne wyjscia status/list-jobs/monitor/progress/show-config --json z
# kolektora labowego pve10 (w tym stan PAUZY: pause-client, odczyt, resume) i
# list-replicas --json z pve9 na tymczasowym configu. Recznie pisany JSON
# zgadzalby sie z ekranem z definicji -- ta sama wada, ktora opisuje suita
# realshape. Stare fikstury hostA (jobs/monitors/unreadable/empty) zostaja:
# maja kierunki push/local/pull i werdykty WARNING/CRITICAL, ktorych lab nie
# dal, i blok nieczytelny.
# ============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$REPO/test/tui/fixtures"
P10="$FIX/pve10"
TUI="$REPO/tui/zfs-tui.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; shift; [ $# -gt 0 ] && printf '  %s\n' "$@"; }

# INTERPRETER WYBIERANY PRZEZ URUCHOMIENIE, nie przez `command -v`: na Windows
# `python3` jest aliasem sklepowym, ktory sie rozwiazuje i drukuje "nie
# znaleziono Python". Nazwa sie rozwiazuje nie znaczy, ze dziala (R1).
PY=""
for c in python3 python; do "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -n "$PY" ] || { echo "FATAL: brak dzialajacego interpretera python" >&2; exit 2; }
export PYTHONIOENCODING=utf-8

export ZFS_TUI_LANG=pl   # okna po polsku niezależnie od settings.ini hosta (testy języka niżej zdejmują to)
# U111: nazwy hostów z WŁASNEGO pliku -- /etc/hosts maszyny testowej (pve9 zna .99, runner CI
# nie) nie może zmieniać wyniku. .99 = pve9; reszta adresów fikstur bez wpisu (-> nazwa relacji).
ZFS_TUI_HOSTS="$(mktemp)"; printf '192.168.28.99 pve9.lab pve9\n' > "$ZFS_TUI_HOSTS"; export ZFS_TUI_HOSTS
NOW=1788960000   # 2026-09-09, srodek dnia -- deterministyczny "nastepny bieg"
ALL="--status $P10/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor.json --progress $P10/progress.json --replicas $P10/replicas.json --config $P10/show-config.json --stats $P10/job-stats.json"
PAUSED="--status $P10/status-paused.json --jobs $P10/list-jobs.json --monitors $P10/monitor-paused.json --progress $P10/progress.json --replicas $P10/replicas.json"

screen() {   # <screen> [keys] [extra args...] -> ekran jako tekst, fikstury pve10
    local sc="$1" keys="${2:-}"; shift; [ $# -gt 0 ] && shift
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen "$sc" --keys "$keys" "$@" 2>&1
}
has()  { printf '%s' "$1" | grep -qF -- "$2"; }
hasE() { printf '%s' "$1" | grep -qE -- "$2"; }

# F2 = PRZEBIEGI: wiersz to BIEG (Kiedy | Relacja | Co | Wynik | Czas), nie zadanie, a lista
# idzie wg czasu -- zadanie nie ma juz "swojego" numeru wiersza. Wiersz zadania znajdujemy
# po tresci: zkeys drukuje "down,down,..." od kursora na wierszu 0 do pierwszego wiersza
# listy pasujacego do wzorca (puste = wiersz 0; rc 1, gdy takiego wiersza nie ma). Lista
# z --height 400 ma wszystkie wiersze; wiersz i lezy w linii 5+i. 'down' przeskakuje wiersze
# tylko do czytania (kreska "teraz", naglowek grupy), wiec ich nie liczymy.
KD='[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2}'   # komorka Kiedy: "dd.mm HH:MM"
# Sama LISTA (lewa strona ramki): wiersz listy dzieli linie z wierszem panelu, a panel ma
# 'OK', 'BŁĄD (rc=1)', 'wysyłka' we wlasnych slowach -- wzorzec z '.*' bez tego lapie panel.
lst() { printf '%s\n' "$1" | sed 's/║│.*//'; }
zkeys() {   # <wzorzec wiersza listy> [argumenty zrodel: --status/--jobs/...] -> klucze
    local rx="$1" full ln dv n keys="" i
    shift
    full="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" "$@" --screen zadania --keys "" --width 200 --height 400 2>&1)"
    ln=$(printf '%s\n' "$full" | sed 's/║│.*//' | grep -nE -- "$rx" | head -1 | cut -d: -f1)
    [ -n "$ln" ] || return 1
    dv=0
    [ "$ln" -gt 6 ] && dv=$(printf '%s\n' "$full" | sed -n "6,$((ln-1))p" | grep -cE '^║ (── teraz|▸ )')
    n=$((ln - 5 - dv))
    keys="home"   # F2 startuje przy "teraz"; liczymy od gory listy
    for ((i=0; i<n; i++)); do keys="$keys,down"; done
    printf '%s' "$keys"
}

# ============================================================================
# EKRAN 1: RELACJE -- wiersz to RELACJA (para hostow), nie zadanie
# ============================================================================
S="$(screen relacje)"
S120="$(screen relacje "" --width 120)"
S200="$(screen relacje "" --width 200)"
# F3 W TRZECH PANELACH (szkic wlasciciela, 2026-09-11): lista jest WASKA, wiec
# kolumny Kopie i Nastepny dochodza z szerokoscia; przy 80 sa trzy.
if hasE "$S200" '^║ lab-ct201 +backup +pve9 → pve10 +działa +aktualne +║│'; then
    ok "relacje: jeden wiersz na RELACJE -- nazwa, typ, KIERUNEK (ten host po lewej), stan z rekordu, kopie z monitora (U21: GB i nastepny bieg w panelu)"
else
    bad "relacje: wiersz relacji sklejony z czterech czytelnikow" "$S200"
fi
if hasE "$S" '^║ lab-ct201 +działa +aktualne +║│' && hasE "$S" '^║ Relacja +Stan +Kopie +║│' && hasE "$S120" '^║ lab-ct201 +backup +pve9 → pve10 +działa +aktualne +║│'; then
    ok "relacje: przy 80 lista ma Relacja, Stan, Kopie; przy 120 dochodza Typ i Kierunek -- panel stoi obok od 80"
else
    bad "relacje: kolumny listy rosna z szerokoscia" "$S" "$S120"
fi
if hasE "$S120" 'Ostatni bieg +brak wpisu w'; then
    ok "relacje: ostatni bieg jest w panelu (U21: grupa Teraz)"
else
    bad "relacje: ostatni wynik w panelu" "$S120"
fi
# Wlasciciel, 2026-09-08: wiersz ma byc relacja. Szczeble drabiny (keep_hourly...)
# to zadania i na ekranie glownym ich NIE ma.
if ! has "$S" 'keep_hourly' && ! has "$S" 'standard_hourly'; then
    ok "relacje: ...a szczeble/zadania NIE sa wierszami ekranu glownego"
else
    bad "relacje: zadania wyciekly na ekran glowny" "$S"
fi
if has "$S" 'pve10 | konto root'; then
    ok "relacje: pasek tytulu nazywa host i KONTO, ktorego crontab jest czytany"
else
    bad "relacje: host i konto w pasku" "$S"
fi
# R3-1: IP hosta obok jego nazwy w pasku tytulu -- w trybie offline/testowym
# przez --host-ip (bez niego, offline, brak IP w pasku: nie wywolujemy 'ip').
SIP="$(screen relacje "" --host-ip 10.9.9.9)"
if has "$SIP" 'pve10 10.9.9.9 |'; then
    ok "relacje: pasek tytulu z --host-ip pokazuje IP obok nazwy hosta"
else
    bad "relacje: --host-ip w pasku tytulu" "$SIP"
fi
if ! has "$S" '10.9.9.9' ; then
    ok "relacje: bez --host-ip w offline pasek nie wymysla adresu"
else
    bad "relacje: pasek bez --host-ip" "$S"
fi
if has "$S" 'Relacje na kolektorze pve10 (5)'; then
    ok "relacje: tytul ramki liczy relacje ZYWE (5), bez rekordu usunietego"
else
    bad "relacje: licznik relacji" "$S"
fi
# Relacja w zasiewie: zamiast godziny -- NASTEPNY KROK slowami CLI.
if hasE "$S200" '^║ duplikat +backup +pve10 [?] pve9 +1\. kopia +-- +║' && hasE "$S120" 'Następny +seed duplikat'; then
    ok "relacje: relacja nieaktywna pokazuje w panelu NASTEPNY KROK CLI (seed duplikat), nie godzine z crona"
else
    bad "relacje: nastepny krok dla relacji w zasiewie" "$S200" "$S120"
fi
# Rekord usuniety jest faktem, ale nie robota: jest, i jest OSTATNI.
if [ "$(printf '%s\n' "$S" | grep -n '192.168.28.99 *usunięta' | cut -d: -f1)" -gt "$(printf '%s\n' "$S" | grep -n '^║ lab-vm101' | cut -d: -f1)" ] 2>/dev/null; then
    ok "relacje: rekord 'removed' jest widoczny i stoi na koncu listy"
else
    bad "relacje: rekord removed" "$S"
fi
# Panel OBOK listy (prawy): pierwszy wiersz (duplikat) ma focus; zrodla i cel
# NIE sa w panelu -- sa w dolnym panelu par (wlasciciel 2026-09-11).
if has "$S" 'duplikat -- relacja' && ! has "$S" 'Źródła' && ! hasE "$S" '│ Cel ' && has "$S200" "brak wpisu w historii transferów"; then
    ok "relacje: prawy panel mowi o wierszu z focusem i tlumaczy brak historii; zrodel i celu w nim NIE ma (sa w zakladce Datasety)"
else
    bad "relacje: panel szczegolow" "$S" "$S200"
fi
if has "$S" 'duplikat (wg rekordu, nie crona): [Datasety]  Zadania' && has "$S120" 'pve9:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "relacje: dolny panel -- relacja BEZ crona (seeding) ma dataset policzony z rekordu i tytul to MOWI"
else
    bad "relacje: pary z rekordu" "$S" "$S120"
fi
S4="$(screen relacje down,down,down,down --width 200 --height 40)"
S4Z="$(screen relacje down,down,down,down,tab,right --width 200 --height 40)"
if has "$S4" 'lab-vm101 -- relacja' && hasE "$S4" 'Następny +2026-09-09 [0-9]{2}:24:00' && hasE "$S4Z" 'pobranie +automated_hourly +co godzinę \(:24\)' && ! has "$S4" 'Wysyłka'; then
    ok "relacje: kursor przesuwa panel; nastepny bieg z harmonogramu; zadanie pobrania w zakladce Zadania (U21)"
else
    bad "relacje: kursor i nastepny bieg" "$S4" "$S4Z"
fi
if hasE "$S4" 'Kopie +aktualne   alarm po 150m'; then
    ok "relacje: panel nazywa prog alarmu przy werdykcie"
else
    bad "relacje: progi w panelu" "$S4"
fi
if hasE "$S4Z" 'lokalny prune +automated_hourly +co godzinę \(:44\) +24 godz\.' && hasE "$S4Z" 'zdalny prune +automated_hourly +co godzinę \(:03\) +24 godz\.' \
   && ! has "$S4Z" 'Porządki' && ! has "$S4Z" 'U źródła'; then
    ok "relacje: zakladka Zadania -- lokalny i zdalny prune w OSOBNYCH wierszach: harmonogram slowami, retencja z jednostka (U21)"
else
    bad "relacje: porzadki w panelu" "$S4Z"
fi
# TESTER R4 (2026-09-25): B1 listwa F3 z akcjami, B3 Szczeble bez 'x',
# B5 panel F2 z retencja z jednostka jak kolumna Trzyma.
if has "$S4" 'F7 Uruchom teraz F8 Pauza F9 Eksport/Import' && ! hasE "$S4" '║.* x[0-9]+ +[0-9/]+s' && ! hasE "$S4" 'aktualne +x[0-9]'; then
    ok "relacje: listwa F3 podpisuje akcje okna (F7 Uruchom teraz F8 Pauza F9 Eksport/Import, jednolicie z F2/F6); kolumna Szczeble bez 'x' (tester R4: B1, B3)"
else
    bad "relacje: listwa F3 / Szczeble" "$S4"
fi
SPW="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down --width 160 2>&1)"
if has "$SPW" 'F8 Wznów F9 Eksport/Import' && ! has "$SPW" 'F8 wznów' && ! has "$SPW" 'F8 Pauza'; then
    ok "relacje: na WSTRZYMANEJ relacji pasek mowi 'F8 Wznow', nie 'Pauza' (tester R4: B6); ramka bez F (uwaga 4)"
else
    bad "relacje: podpis F7 na pauzie" "$SPW"
fi
# F2 Przebiegi: panel wiersza porzadkow (nie wiersz nr 1 -- lista idzie wg czasu).
ZT="$(screen zadania "$(zkeys "^║ $KD +lab-vm101 +lokalny prune " $ALL)" --width 100 --height 40)"
if hasE "$ZT" 'Trzyma +24 godz\.' && ! hasE "$ZT" 'Trzyma +-H24'; then
    ok "zadania: panel 'Trzyma' z jednostka, nie surowe -H24 (tester R4: B5)"
else
    bad "zadania: panel trzyma" "$ZT"
fi
if hasE "$S4" 'Wywołania +[0-9]+, błędów [0-9]+' && hasE "$S4" 'Czas +ostatni [0-9]+s / średni' && hasE "$S4" 'Dane +[0-9.]+[KMG]' \
   && hasE "$S4" 'Powstała +2026-09-08' && hasE "$S4" 'Pełna kopia +2026-09-08' && ! has "$S4" 'Zasiew' && hasE "$S4" 'Aktywna od +2026-09-08'; then
    ok "relacje: panel jako TABELA -- jeden fakt w wierszu: wywolania, czas ostatni/sredni/maks, dane, powstala/pelna kopia/aktywna od (U21: grupy Teraz, Przebiegi, Ustawienia)"
else
    bad "relacje: statystyka/historia w panelu" "$S4"
fi
# DOLNY PANEL Z CRONA: para w jednej linii, gdy sie miesci (200); inaczej
# zrodlo i pod nim cel (80, 120). Od 100 kolumn kopie, czas i GB per para --
# te same liczby co F2 -- przy ostatniej linii pary.
# R5-4: nazwy kolumn w WIERSZU NAGLOWKA nad kolumnami, nie w tytule ramki, i
# wartosc pod swoim naglowkiem (ta sama kolumna tekstu), bez dziury.
# Pozycja w ZNAKACH, nie bajtach ("Zrodlo" ma litery wielobajtowe; wc -m na
# Git Bash liczy bajty) -- liczy Python.
S4H="$(printf '%s\n' "$S4" | grep -E '║ Źródło → cel +Kopie +Szczeble +Dane 7 dni' | head -1)"
S4R="$(printf '%s\n' "$S4" | grep -E '^║ pve9:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101 +aktualne +[0-9]+ +[0-9.]+[KMG]' | head -1)"
_same=$("$PY" -c 'import sys; h,r=sys.argv[1],sys.argv[2]; print(1 if h and r and h.index("Kopie")==r.index("aktualne") else 0)' "$S4H" "$S4R" 2>/dev/null)
if has "$S4" 'lab-vm101: [Datasety]  Zadania' && [ -n "$S4H" ] && [ -n "$S4R" ] && [ "$_same" = 1 ]; then
    ok "relacje: zakladka Datasety przy 200 -- wiersz naglowka nad kolumnami, para w jednej linii, Kopie pod Kopie (R5-4)"
else
    bad "relacje: pary przy 200" "$S4"
fi
# ZEPSUTE ZRODLO MA NAZWAC KOMENDE. Ekran mowil "uruchom czasownik recznie",
# czyli kazal zgadnac, ktory to czasownik i z jaka flaga -- a zna jedno i drugie.
# (Ten sam kontrakt dla verba "monitor" byl tu sprawdzany na usunietym ekranie
# F5 -- kontrola ujemna na "progress" i "list-replicas" zostaje nizej.)
BAD="$(mktemp -d)/bad.json"; printf '{ZEPSUTY
' > "$BAD"
EB="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen zadania --keys "" --jobs "$BAD" --width 100 2>&1)"
if has "$EB" 'zfs-backup.sh list-jobs --json' && has "$EB" 'błąd źródła' && ! has "$EB" 'Uruchom czasownik ręcznie'; then
    ok "zepsute zrodlo: ekran nazywa DOKLADNA komende do wpisania, zamiast odsylac do 'czasownika'"
else
    bad "zepsute zrodlo: brak komendy" "$EB"
fi

# POMOC MA OPISYWAC TO, CO JEST. Po usunieciu kreatora curses (2026-09-21)
# ekran F1 nadal opisywal jego siedem krokow i klawisze, ktorych juz nie ma --
# tekst pomocy to tez ekran, i tez sie dezaktualizuje.
H1="$(screen zadania F1 --width 100 --height 120)"
# A-1 (kampania 2026-10-21): po przebudowie (U66) kreator idzie krok po kroku z podsumowaniem.
if ! has "$H1" 'kreator w 7 krokach' && ! has "$H1" 'Enter na źródle/celu' && ! has "$H1" 'kreator w 10 krokach' \
   && has "$H1" 'kreator krok po kroku' && has "$H1" 'Wstecz = poprzedni krok' && has "$H1" 'Zaawansowane' && has "$H1" 'whiptail'; then
    ok "pomoc: opisuje kreator, ktory NAPRAWDE sie otwiera (krok po kroku, podsumowanie, Zaawansowane), a nie poprzednikow"
else
    bad "pomoc: nieaktualny opis kreatora" "$(printf '%s' "$H1" | sed -n '4,14p')"
fi
# R4-2: pomoc mowi, ze F7-F9 to akcje okna, Ctrl-R odswieza, a litery NIGDY nie sa skrotami.
# F5 od 2026-10-09 to ekran Szablony (uwaga 24), odswiezanie zostaje pod Ctrl-R.
if has "$H1" "główne okna (F4 Kopie" && ! has "$H1" "F7 chowa/pokazuje transfery" && ! has "$H1" "F11 " \
   && has "$H1" "F7 F8 F9          akcje BIEŻĄCEGO okna" \
   && has "$H1" "Ctrl-R            odśwież" && ! has "$H1" "F5 / Ctrl-R" && ! has "$H1" "wyjątek: 'u'" && ! has "$H1" "F9 / Ctrl-R"; then
    ok "pomoc: F7-F9 = akcje okna, Ctrl-R odswieza, bez wyjatku dla liter (R4-2)"
else
    bad "pomoc: klawisze R4-2" "$H1"
fi

# SZEROKOSC: KOLUMNY PO PRIORYTECIE (R3-4). F2 Przebiegi ma piec kolumn: Kiedy,
# Relacja, Co, Wynik, Czas -- od najwazniejszej; gdy lista jest za waska, odpada
# najpierw Czas, potem Co (Relacja sie zwija do 12 znakow, nie znika). Kierunek,
# Prefiks, Nastepny, Kopie i retencja zniknely z LISTY (kierunek, harmonogram, retencja
# -- w panelu; prefiks i werdykt -- na F3). Panel idzie OBOK listy od 150, nie od 120
# jak wczesniej (punkt 3) -- 120 zabieral liscie miejsce, ktorego panelowi i tak nie
# oddawal w calosci.
# Ucinanie sprawdzamy tylko po LEWEJ stronie ramki (panel obok ma wlasne zawijanie).
Z100="$(screen zadania "" --width 100)"
Z100L="$(printf '%s\n' "$Z100" | sed -n '3,6p' | sed 's/║│.*//')"
Z100H="$(lst "$Z100" | sed -n '3p')"   # sam naglowek listy (dolna zakladka tez ma 'Wynik')
if has "$Z100H" 'Kiedy' && has "$Z100H" 'Relacja' && has "$Z100H" 'Wynik' && ! printf '%s\n' "$Z100L" | grep -q '…'; then
    ok "zadania: przy 100 kolumnach lista ma Kiedy, Relacje i Wynik, nic nie uciete (Czas i Co spadaja pierwsze)"
else
    bad "zadania: kolumny przy 100" "$(printf '%s' "$Z100" | sed -n '3,5p')"
fi
# 260: od 150 panel stoi obok i lista ma 60% szerokosci; wszystkie piec kolumn
Z160="$(screen zadania "" --width 260)"
Z160H="$(printf '%s\n' "$Z160" | sed -n '3p')"
if hasE "$Z160H" 'Kiedy {2,}Relacja {2,}Co {2,}Wynik {2,}Czas' \
   && ! has "$Z160H" 'Prefiks migawek' && ! has "$Z160H" 'Następny' && ! has "$Z160H" 'Kopie' \
   && ! has "$Z160H" 'Harmonogram' && ! has "$Z160H" 'Czas o/ś/m' && ! has "$Z160H" 'szt.'; then
    ok "zadania: przy 260 kolumnach piec naglowkow listy: Kiedy, Relacja, Co, Wynik, Czas (kierunek, harmonogram, retencja -- w panelu; prefiks i kopie -- na F3)"
else
    bad "zadania: naglowki przy 160" "$Z160H"
fi
if [ "$(printf '%s\n' "$Z160" | grep -c '║.*│')" -gt 0 ]; then
    ok "zadania: przy 160 panel stoi OBOK listy (prog 150, nie 120)"
else
    bad "zadania: panel obok przy 160" "$Z160"
fi
Z120="$(screen zadania "" --width 120)"
if [ "$(printf '%s\n' "$Z120" | grep -c '║.*│')" -gt 0 ]; then
    ok "zadania: przy 120 panel stoi OBOK listy (U21: pod spodem sa przebiegi)"
else
    bad "zadania: panel pod lista przy 120" "$Z120"
fi
for _w in 80 100 120 140 160 200; do
    _h="$(screen zadania "" --width $_w | sed -n '3p')"
    case "$_h" in
        *"Czas..."*|*"Wynik…"*|*"Wynik..."*|*"Relacj…"*|*"Relacj..."*|*"Kiedy…"*|*"Kiedy..."*) bad "zadania: uciety NAGLOWEK kolumny przy $_w" "$_h" ;;
        *) ok "zadania: przy $_w kolumnach zaden naglowek kolumny nie jest uciety" ;;
    esac
done

# SYNCHRO JAKO LUSTRO (wlasciciel 2026-10-06): zadanie pobrania, ktorego WLASNA
# linia snapget niesie -M, nie ma wlasnej retencji celu -- F2 'Trzyma' mowi
# "lustro", a nie szablonowe 168 szt. Linia CUDZEGO zadania z -M (ten sam blok,
# inny dataset) nie czyni lustrem tego zadania.
MIOUT="$("$PY" - "$TUI" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
mir = {"tier": "passive_flat_hourly", "scope": "hdd/x", "cron_lines": [
    '31 * * * * zfs-job.sh "h profile__passive-flat__passive_flat_hourly backup (r-x)" -- snapget.sh -m "" -e -M -L r "u@h:hdd/x"']}
plain = {"tier": "passive_flat_hourly", "scope": "hdd/y", "cron_lines": [
    '31 * * * * zfs-job.sh "h profile__passive-flat__passive_flat_hourly backup (r-y)" -- snapget.sh -m "" -e -L r "u@h:hdd/y"',
    '31 * * * * zfs-job.sh "h profile__passive-flat__passive_flat_hourly backup (r-x)" -- snapget.sh -m "" -e -M -L r "u@h:hdd/x"']}
print("%s %s" % (m.job_is_mirror(mir), m.job_is_mirror(plain)))
PYEOF
)"
if [ "$MIOUT" = "True False" ]; then
    ok "lustro: -M we WLASNEJ linii pobrania czyni zadanie lustrem; cudza linia z -M w tym samym bloku -- nie"
else
    bad "lustro: -M we WLASNEJ linii pobrania czyni zadanie lustrem; cudza linia z -M w tym samym bloku -- nie" "got=$MIOUT"
fi

# ODSWIEZANIE PO POWROCIE (wlasciciel 2026-10-09, uwaga 1: zapisany szablon pojawial sie na
# F5 dopiero po Odswiez). Pelne refresh() czyta od nowa takze dane czytane na zadanie:
# szablony (F5) i config relacji (panel F3). Plik szablonow podmieniony miedzy odczytami
# = to, co robi save-profile w oknie potomnym.
RFOUT="$("$PY" - "$TUI" <<'PYEOF'
import sys, json, os, tempfile, importlib.util
spec = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
d = tempfile.mkdtemp()
pf = os.path.join(d, "profiles.json")
def put(names):
    json.dump({"profiles": [{"name": n, "source": "user", "tiers": []} for n in names]}, open(pf, "w"))
put(["a"])
files = {"profiles": pf, "offline": True}
ui = m.UI(d, files, m.Chars(True), 1700000000, None)
ui.screen = "szablony"
ui.ensure_profiles()
n1 = ui.count("szablony")
put(["a", "FLAT_W4HD7H12"])
ui.data.configs["r1"] = ("stary", None)
ui.refresh()
print("%d %d %s" % (n1, ui.count("szablony"), "r1" in ui.data.configs))
PYEOF
)"
if [ "$RFOUT" = "1 2 False" ]; then
    ok "odswiezanie: pelne odswiezenie czyta szablony (F5) i config relacji od nowa -- zapisany szablon od razu na liscie"
else
    bad "odswiezanie: szablony i config po powrocie" "got=$RFOUT (chce: 1 2 False)"
fi

# KOLUMNA NASTEPNY -- format wg R3-4 (test b): dzis tylko godzina, jutro
# "jutro HH:MM", w tygodniu dwuliterowy dzien tygodnia, dalej "DD.MM HH:MM".
# Liczone NIEZALEZNIE od tablicy dni tygodnia w module (WD ponizej to REFERENCJA
# z brief'u, nie import z zfs-tui.py) -- inaczej test bylby tautologia.
NXOUT="$("$PY" - "$TUI" <<'PYEOF'
import sys, time, importlib.util
spec = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
now = time.mktime((2026, 9, 9, 12, 0, 0, 0, 0, -1))
WD = [u"pn", u"wt", u"śr", u"cz", u"pt", u"so", u"nd"]  # pon..niedz, z brief'u R3-4
cases = [
    ("today", time.mktime((2026, 9, 9, 14, 0, 0, 0, 0, -1)), "14:00"),
    ("tomorrow", time.mktime((2026, 9, 10, 9, 5, 0, 0, 0, -1)), u"jutro 09:05"),
    ("far", time.mktime((2026, 9, 20, 10, 30, 0, 0, 0, -1)), "20.09 10:30"),
]
ok_all = True
for name, epoch, want in cases:
    got = m.fmt_next_short(epoch, now)
    print("%s|%s|%s" % (name, got, want))
# "w tygodniu" liczone z prawdziwym dniem tygodnia (nie zgadujemy kalendarza recznie)
week_epoch = time.mktime((2026, 9, 14, 8, 0, 0, 0, 0, -1))
wd = WD[time.localtime(week_epoch).tm_wday]
print("week|%s|%s 08:00" % (m.fmt_next_short(week_epoch, now), wd))
PYEOF
)"
NXBAD=""
while IFS='|' read -r nm got want; do
    want=${want%$'\r'}   # print pythona na Windows konczy linie CRLF
    [ "$got" = "$want" ] || NXBAD="$NXBAD $nm(got=$got,want=$want)"
done <<EOF
$NXOUT
EOF
if [ -z "$NXBAD" ]; then
    ok "zadania: fmt_next_short -- dzis/jutro/tydzien/DD.MM zgodne ze specyfikacja R3-4"
else
    bad "zadania: fmt_next_short" "$NXBAD" "$NXOUT"
fi

# JEDNO OSTRZEZENIE NA FAKT. Relacja ma monitor na kazdy szczebel, wiec uwaga
# "cron wola inny plik silnika" wchodzila do panelu tyle razy, ile szczebli, i
# wypychala z niego Stan/Typ/Kierunek (zmierzone na pve10, 2026-09-21).
S4W="$(screen relacje down --width 200)"
_w=$(printf '%s' "$S4W" | grep -c 'cron woła inny plik silnika' || true)
if [ "$_w" -le 1 ]; then
    ok "relacje: to samo ostrzezenie nie powtarza sie raz na monitor -- panel zostaje czytelny"
else
    bad "relacje: powtorzone ostrzezenie w panelu" "wystapien: $_w"
fi

# JEDEN DATASET = JEDEN WIERSZ, cztery szczeble = "x4" w kolumnie. Relacja
# lab-ct201 ma w atrapie cztery linie crona nad jednym datasetem; przed
# 2026-09-21 panel rysowal ja CZTERY RAZY i nazywal "4 pary" (zmierzone na
# pve10). Liczy sie i to, co widac, i co mowi tytul.
S4CT="$(screen relacje down --width 200)"
_ct=$(printf '%s' "$S4CT" | grep -cE '^║ pve9:hdd/lab/ct-201 → ')
if [ "$_ct" -le 1 ] && ! has "$S4CT" 'ct-201: 4 pary'; then
    ok "relacje: dataset z kilkoma szczeblami zajmuje JEDEN wiersz panelu, nie tyle wierszy, ile ma linii crona"
else
    bad "relacje: powtorzony dataset w panelu par" "wierszy ct-201: $_ct" "$(printf '%s' "$S4CT" | grep -E 'Datasety relacji' | head -1)"
fi

S4_120="$(screen relacje down,down,down,down --width 120)"
if hasE "$S4_120" '^║ pve9:hdd/lab/vm-101 → .* +aktualne +1 +[0-9.]+[KMG] +║'; then
    ok "relacje: przy 120 dataset w jednym wierszu z liczbami; pelne sciezki w panelu po Tab"
else
    bad "relacje: pary przy 120" "$S4_120"
fi
S4_80="$(screen relacje down,down,down,down)"
if hasE "$S4_80" '^║ pve9:hdd/.* +aktualne +1 +[0-9.]+[KMG] +║'; then
    ok "relacje: ...a przy 80 to samo, sciezka skrocona"
else
    bad "relacje: pary przy 80" "$S4_80"
fi
# PODZIAL WYSOKOSCI (wlasciciel 2026-09-12: "co gdy datasetow bedzie 20?"):
# gora tyle, ile trzeba liscie i panelowi, dol -- CALA reszta.
S40="$(screen relacje down,down,down,down --width 160 --height 40)"
if [ "$(printf '%s\n' "$S40" | grep -c '^║ .*║$')" -ge 10 ] && [ "$(printf '%s\n' "$S40" | grep -c '^║.*║│')" -le 24 ]; then
    ok "relacje: przy 40 wierszach dol ma co najmniej 10 linii na pary, gora nie rosnie ponad potrzebe listy i panelu"
else
    bad "relacje: podzial wysokosci" "$S40"
fi
# TAB: kursor na pary; Enter na parze otwiera OKNO tej pary (R4-6), nie skok na F2.
TP="$(screen relacje down,tab)"
if has "$TP" 'm migawki   Enter okno   ←→ zakładki   Esc wraca   Tab do linii poleceń' && has "$TP" 'lab-ct201 -- dataset'; then
    ok "relacje: Tab przenosi kursor na datasety, prawy panel pokazuje zaznaczony dataset (U21); na ramce m migawki (U38)"
else
    bad "relacje: Tab" "$TP"
fi
TE="$(screen relacje down,tab,enter --height 60)"
if ! has "$TE" 'Zadania na pve10' && has "$TE" '╔═ Zadanie: lab-ct201  pobranie  automated_hourly' \
   && hasE "$TE" 'Źródło +pve9:hdd/lab/ct-201' && has "$TE" '── CONFIG ' && has "$TE" '── CRON ' \
   && has "$TE" 'snapget.sh -m'; then
    ok "relacje: Enter na datasecie = okno jego zadania (szczegoly, CONFIG, CRON) na F3, bez skoku na F2 (R4-6)"
else
    bad "relacje: Enter na parze" "$TE"
fi
TEE="$(screen relacje down,tab,down,enter,esc)"
if has "$TEE" 'Relacje na kolektorze' && has "$TEE" 'Enter okno   ←→ zakładki' && ! has "$TEE" '╔═ Zadanie:'; then
    ok "relacje: Esc z okna datasetu wraca na dolny panel (kursor zostaje na datasetach)"
else
    bad "relacje: Esc z okna pary" "$TEE"
fi
TR="$(screen relacje tab,enter)"
if has "$TR" 'Relacje na kolektorze' && has "$TR" 'ten dataset jest tylko w definicji relacji, nie w cronie'; then
    ok "relacje: Enter na datasecie z REKORDU mowi, ze nie ma jego linii ani sekcji"
else
    bad "relacje: Enter na parze z rekordu" "$TR"
fi

# --- PAUZA: prawdziwy stan z pause-client na pve10 -------------------------
SP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down --width 200 2>&1)"
if hasE "$SP" '^║ lab-srv-b +backup +pve9 → pve10 +działa PAUZA +aktualne +║' && hasE "$SP" 'Następny +-- pauza --'; then
    ok "relacje: relacja wstrzymana ma PAUZA w stanie, a panel '-- pauza --' zamiast nastepnego biegu"
else
    bad "relacje: wiersz pauzy" "$SP"
fi
if hasE "$SP" 'Uwaga +relacja wstrzymana .pause-client.'; then
    ok "relacje: ...a panel mowi, ze starzenie kopii jest tu oczekiwane"
else
    bad "relacje: uwaga o pauzie w panelu" "$SP"
fi

# --- ZADANIA BEZ REKORDU RELACJI (hostA: push/local/pull, WARNING/CRITICAL) --
H="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen relacje --width 200 2>&1)"
if has "$H" 'bez rekordu → pve9' && has "$H" 'bez rekordu → tutaj' && has "$H" 'bez rekordu ← pve1'; then
    ok "relacje: sekcje configu bez rekordu relacji (ksztalt PRODUKCJI: 0/7 hostow ma rekordy) sa wierszami z kierunkiem, nie sa chowane"
else
    bad "relacje: zadania bez rekordu" "$H"
fi
# DYSKRYMINATOR DOPASOWANIA: dla POBRANIA monitor pilnuje lokalnego CELU, a
# zakres zadania to zdalne ZRODLO; laczy je etykieta relacji. Bez tego wiersz
# pull mial 'bez monitora' przy monitorze mowiacym CRITICAL.
if hasE "$H" 'vm-100-disk-0 .*stare'; then
    ok "relacje: werdykt pobrania dopasowany po ETYKIECIE relacji (stare, nie 'bez monitora')"
else
    bad "relacje: werdykt pull po etykiecie" "$H"
fi
if hasE "$H" 'subvol-100-disk-0 .*spóźnione' && hasE "$H" 'rpool/ROOT/os .*aktualne'; then
    ok "relacje: werdykt stoi przy WLASCIWYM zakresie (spoznione / aktualne)"
else
    bad "relacje: werdykty przy swoich zakresach" "$H"
fi

# --- BLOK NIECZYTELNY JEST WIERSZEM ------------------------------------------
U="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/unreadable.json" --monitors "$FIX/monitors.json" --screen relacje --width 200 2>&1)"
if hasE "$U" 'konto backupacct +[?] +[?] +nieczytelny +nie odpowiada'; then
    ok "relacje: blok bez czytelnego configu jest WIERSZEM z liczba linii, ktore chodza"
else
    bad "relacje: nieczytelny blok jako wiersz" "$U"
fi

# --- HOST, KTORY NAPRAWDE NIC NIE MA -----------------------------------------
E="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/empty-mon.json" --screen relacje 2>&1)"
if has "$E" "Brak relacji zfs-backup na tym hoście" && has "$E" "Ins = nowa relacja"; then
    ok "relacje: pusty host tlumaczy sie (brak rekordu i bloku, nie brak backupow)"
else
    bad "relacje: pusty host" "$E"
fi

# ============================================================================
# EKRAN F2: ZADANIA -- co chodzi w cronie, z relacja i KIERUNKIEM
# ============================================================================
# Wlasciciel, 2026-09-09: "obok kolumny relacja wstaw kolumne z kierunkiem np.
# pve9>pve10, lub pve9<>pve10, lub local" -- lewa strona to ZAWSZE ten host.
# R4-4: Prefiks i Trzyma wchodza od ~100 kolumn (przy 80 nie ma na nie miejsca).
# BEZ fikstury replik (2026-10-08): repliki sa wierszami F2, a replika sejf-a ma
# nastepny bieg "jutro 02:30" -- kolumna Nastepny rosnie o 6 znakow i przy 100
# kolumnach Prefiks spada. Tak samo bywa na hoscie, gdy najblizszy bieg zadania
# dobowego jest jutro; te testy pinuja tresc wierszy relacji przy 100 kolumnach,
# wiersze replik maja wlasne testy przy NOSNIKACH.
Z="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --progress "$P10/progress.json" --config "$P10/show-config.json" --stats "$P10/job-stats.json" --screen zadania --width 160 2>&1)"
if has "$Z" '╔═ Przebiegi na pve10 -- wykonane 12h i nadchodzące 6h'; then
    ok "zadania: F2 to Przebiegi -- tytul nazywa host i okno: wykonane 12h, nadchodzace 6h (nie liczy zadan ani relacji)"
else
    bad "zadania: tytul" "$Z"
fi
# F2 Przebiegi: wiersz to BIEG, lista idzie wg czasu. Wiersz zadania znajdujemy po tresci
# (zkeys), panel (kierunek, retencja) jest ten sam co dawniej, tylko pod grupa
# "Nadchodzacy bieg". Prefiks migawek (automated_hourly) zniknal z F2 -- jest na F3, w
# zakladce Zadania (test 'pobranie +automated_hourly +co godzinę' wyzej); tu wiersz niesie
# zadanie i szczebel w kolumnie Co.
# Szerokosc 200: przy ciasnej liscie odpada kolumna Co (prio), a ona niesie zadanie.
ZW="$(screen zadania "$(zkeys "^║ $KD +lab-vm101 +pobranie " $ALL)" --width 200 --height 60)"
if hasE "$ZW" "^║ $KD +lab-vm101 +pobranie +standard_hourly: vm-101 +nadchodzący" && hasE "$ZW" 'Kierunek +pve9 → pve10' \
   && has "$ZW" 'Nadchodzący bieg' && ! has "$ZW" 'Zakres'; then
    ok "zadania: POBRANIE nazywa sie pobraniem (nie 'wysylka'), w Co ma szczebel, kierunek 'pve10<peer' w panelu (U21), bez 'Zakres' dla jednego datasetu"
else
    bad "zadania: wiersz wysylki" "$ZW"
fi
ZL="$(screen zadania "$(zkeys "^║ $KD +lab-vm101 +lokalny prune " $ALL)" --width 200 --height 60)"
if hasE "$ZL" "^║ $KD +lab-vm101 +lokalny prune " && hasE "$ZL" 'Kierunek +lokalnie, na tym hoście' && hasE "$ZL" 'Trzyma +24 godz\.'; then
    ok "zadania: porzadki na ladowisku = 'lokalny prune'; w panelu 'lokalnie, na tym hoście' i retencja z jednostka"
else
    bad "zadania: wiersz porzadkow" "$ZL"
fi
ZR="$(screen zadania "$(zkeys "^║ $KD +lab-vm101 +zdalny prune " $ALL)" --width 200 --height 60)"
if hasE "$ZR" "^║ $KD +lab-vm101 +zdalny prune " && has "$ZR" 'lab-vm101 -- ' && hasE "$ZR" 'Kierunek +pve9 → pve10' && ! hasE "$ZR" 'Kierunek +lokalnie'; then
    ok "zadania: porzadki na ZDALNYM zrodle niosa kierunek relacji, nie 'lokalnie'"
else
    bad "zadania: zdalne porzadki" "$ZR"
fi
# CZASY I GB JAK W MAILU (wlasciciel 2026-09-11: "jak w digescie -- spojnie z
# tym co przychodzi na mailu"). Zrodlo: job-stats --json z pve10, doslownie.
# Oczekiwane liczby sa POLICZONE Z FIKSTURY, nie wpisane: etykieta crona
# zadania (bez hosta) -> wiersz job-stats; wolumen = suma bytes rodziny na
# ladowisku i pod nim.
want=$("$PY" - "$P10/job-stats.json" "$P10/list-jobs.json" <<'PYEOF'
import sys, json
st = json.load(open(sys.argv[1])); lj = json.load(open(sys.argv[2]))
j = [x for x in lj["jobs"] if x["label"] == "lab-vm101" and x["section_kind"] == "dataset"][0]
lbl = [l for l in j["cron_lines"] if "snapget.sh" in l][0].split('zfs-job.sh "', 1)[1].split('"', 1)[0].split(" ", 1)[1]
row = [x for x in st["jobs"] if x["label"] == lbl][0]
vol = sum(v["bytes"] for v in st["volume"] if (v["dataset"] == j["scope"] or v["dataset"].startswith(j["scope"] + "/")) and v["family"] == "automated_hourly")
def h(n):
    for u in "BKMGTP":
        if n < 1024 or u == "P": return ("%dB" % n) if u == "B" else "%.1f%s" % (n, u)
        n /= 1024.0
print(row["last_s"], row["avg_s"], row["max_s"], h(vol), row["runs"], row["last_at"])
PYEOF
)
set -- $want
# R3-4: przy 80 kolumnach 'Czas o/ś/m' moze spasc z listy (priorytet 8) --
# sprawdzamy DOKLADNA liczbe na SZEROKIM ekranie (200), gdzie wchodzi caly
# priorytet; wartosc jest ta sama niezaleznie od tego, czy kolumna sie zmiesci.
# R4-4: 11 kolumn -- Czas wchodzi dopiero przy bardzo szerokiej liscie.
# U98: pusta linia przed kazda grupa panelu wydluza go -- przy domyslnych 24 liniach Dane odpadaja
Z200="$(screen zadania "" --width 260 --height 60)"
if hasE "$Z200" "Czas +ostatni ${1}s / średni ${2}s / maks\. ${3}s" && has "$Z200" " $4"; then
    ok "zadania: czasy (${1}/${2}/${3}s) i dane ($4) w panelu pobrania sa DOKLADNIE tym, co job-stats mowi o jej linii crona i jej ladowisku"
else
    bad "zadania: czasy/GB z job-stats" "want: $want" "$Z200"
fi
if hasE "$Z200" "Wywołania +$5, błędów 0" && has "$Z200" "$6 $7   OK" && hasE "$Z200" "Dane +$4"; then
    ok "zadania: panel nazywa wywolania, ostatni bieg z wynikiem i dane z oknem digestu"
else
    bad "zadania: panel czasow" "$Z200"
fi
# bez zrodla: '?' w kolumnach i zdanie w panelu, nie zera
ZSARGS="--status $P10/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor.json --stats $FIX/nie-ma.json"
ZS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZSARGS --screen zadania --keys "$(zkeys "^║ $KD +lab-vm101 +pobranie " $ZSARGS)" --width 200 --height 60 2>&1)"
# F2 Przebiegi: werdykt ('aktualne') nie jest juz w liscie F2 -- mieszka na F3 Relacje
# (testy 'relacje:' wyzej). Lista niesie bieg (Kiedy/Co/Wynik), wiec fakt, ktory tu
# chronimy -- zepsute job-stats to '?' i zdanie, nie zera udajace pomiar -- siedzi w
# panelu wiersza i w pasku tytulu.
ZS_LINE=$(printf '%s\n' "$ZS" | grep -E "^║ $KD +lab-vm101 +pobranie ")
if [ -n "$ZS_LINE" ] && printf '%s' "$ZS_LINE" | grep -qF 'nadchodzący' \
   && has "$ZS" '? -- job-stats nie odpowiedział' && has "$ZS" '! bez odpowiedzi: 1' \
   && ! hasE "$ZS" 'Czas +ostatni 0s' && ! hasE "$ZS" 'Wywołania +0,'; then
    ok "zadania: zepsute job-stats -> '?' i zdanie w panelu (wiersz biegu zostaje), nigdy zero udajace pomiar"
else
    bad "zadania: zepsute job-stats" "$ZS_LINE" "$ZS"
fi
ZH3ARGS="--jobs $FIX/jobs.json --monitors $FIX/monitors.json --stats $P10/job-stats.json"
ZH3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZH3ARGS --screen zadania --keys "$(zkeys "^║ $KD +pve9 +wysyłka " $ZH3ARGS)" --width 200 --height 60 2>&1)"
ZH3_LINE=$(printf '%s\n' "$ZH3" | grep -E "^║ $KD +pve9 +wysyłka ")
# Werdykt 'spóźnione' tego zadania jest na F3 (nie na F2 Przebiegi); tu: wiersz biegu
# istnieje, a panel mowi 'brak biegow' zamiast zer.
if [ -n "$ZH3_LINE" ] && printf '%s' "$ZH3_LINE" | grep -qF 'nadchodzący' \
   && has "$ZH3" 'brak biegów w dzienniku z tego okna'; then
    ok "zadania: zadanie, ktorego nie ma w dzienniku, ma wiersz biegu, a panel mowi 'brak biegow'"
else
    bad "zadania: brak biegow" "$ZH3_LINE" "$ZH3"
fi

# F8/F9 NA F2 PRZEBIEGI (U79/U80). Trzytrybowe sortowanie (F8: relacje / os czasu / ostatni
# bieg, 'sort: ...' w tytule) ZNIKLO razem z kolumnami Prefiks/Nastepny/Kopie: lista to
# jedna os czasu. F8 = Schowaj/Pokaz wykonane (przelacznik), F9 = Grupuj po relacji /
# Jedna os czasu (przelacznik). Fikstura hostA nie ma wykonanych biegow (brak --stats),
# wiec F8 tu zmienia tytul i podpis na pasku; schowanie wierszy i kursor na tym samym
# biegu po F8/F9 -- w sekcji 'przebiegi: wiersze tylko do czytania' nizej (ma wykonany bieg).
# jobs.json (fixture hostA) ma zadanie GODZINOWE "wysyłka hourly" (schedule
# "5 * * * *" -- nastepny bieg w ciagu godziny od NOW) i zadanie DOBOWE
# "kopia daily" (schedule "21 0 * * *" -- NOW jest "środek dnia", 00:21 juz
# minelo, nastepny bieg dopiero jutro) -- kolejnosc miedzy nimi na osi czasu
# jest wiec DETERMINISTYCZNA niezaleznie od dokladnej minuty NOW.
ZJARGS="--jobs $FIX/jobs.json --monitors $FIX/monitors.json"
ZSORT0="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --width 200 --height 100 2>&1)"
ZSORT1="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8 --width 200 2>&1)"
if has "$ZSORT0" 'Przebiegi na ' && has "$ZSORT0" 'wykonane 12h i nadchodzące 6h' && has "$ZSORT0" 'F8 Schowaj wykonane' \
   && has "$ZSORT1" 'Przebiegi na ' && has "$ZSORT1" '-- tylko nadchodzące' && ! has "$ZSORT1" 'wykonane 12h' && has "$ZSORT1" 'F8 Pokaż wykonane' \
   && ! has "$ZSORT1" 'sort:' && ! has "$ZSORT1" 'Sortuj'; then
    ok "zadania: F8 raz -- tytul 'tylko nadchodzące', podpis na pasku 'Pokaż wykonane' (bylo: sort: oś czasu)"
else
    bad "zadania: F8 raz -- tytul" "$ZSORT0" "$ZSORT1"
fi
L1=$(lst "$ZSORT0" | grep -nE "^║ $KD .*wysyłka .*nadchodzący" | head -1 | cut -d: -f1)
L2=$(lst "$ZSORT0" | grep -nE "^║ $KD .*kopia .*nadchodzący" | head -1 | cut -d: -f1)
if [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ]; then
    ok "zadania: os czasu -- 'wysyłka hourly' (biegnie w ciagu godziny) stoi przed 'kopia daily' (biegnie dopiero jutro)"
else
    bad "zadania: kolejnosc wierszy na osi czasu" "L1=$L1 L2=$L2" "$ZSORT0"
fi
ZSORT2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8,F8 --width 200 2>&1)"
if has "$ZSORT2" 'wykonane 12h i nadchodzące 6h' && ! has "$ZSORT2" 'tylko nadchodzące' && has "$ZSORT2" 'F8 Schowaj wykonane'; then
    ok "zadania: F8 dwa razy -- wykonane wracaja (tytul 'wykonane 12h i nadchodzące 6h', pasek 'Schowaj wykonane')"
else
    bad "zadania: F8 dwa razy -- tytul" "$ZSORT2"
fi
ZSORTS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys s --width 200 2>&1)"
if has "$ZSORTS" 'wykonane 12h i nadchodzące 6h' && has "$ZSORTS" '$ s_ '; then
    ok "zadania: 's' to TEKST linii polecen -- widok zostaje (R4-2)"
else
    bad "zadania: 's' jako tekst" "$ZSORTS"
fi
ZSORT3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8,F8,F8 --width 200 2>&1)"
if has "$ZSORT3" '-- tylko nadchodzące' && ! has "$ZSORT3" 'wykonane 12h' && ! has "$ZSORT3" 'po relacjach'; then
    ok "zadania: F8 trzy razy -- to przelacznik, nie cykl: znowu 'tylko nadchodzące'"
else
    bad "zadania: F8 trzy razy -- przelacznik" "$ZSORT3"
fi
ZG9="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F9 --width 200 2>&1)"   # U84: wciecie wiersza grupy = 4 spacje + kreska
ZG99="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F9,F9 --width 200 2>&1)"
if has "$ZG9" 'wykonane 12h i nadchodzące 6h, po relacjach' && hasE "$ZG9" '^║ Kiedy +Zadanie +Co +Wynik' && hasE "$ZG9" '^║ ▸ ' \
   && hasE "$ZG9" "^║     │ $KD " && has "$ZG9" 'F9 Jedna oś czasu' \
   && ! has "$ZG99" 'po relacjach' && hasE "$ZG99" '^║ Kiedy +Relacja +Co +Wynik' && ! hasE "$ZG99" '^║ ▸ ' && has "$ZG99" 'F9 Grupuj po relacji'; then
    ok "zadania: F9 grupuje po relacji (naglowki '▸ NAZWA', wiersze '│ dd.mm HH:MM', kolumna Zadanie, tytul ', po relacjach'); drugi F9 wraca do jednej osi czasu"
else
    bad "zadania: F9 grupowanie" "$ZG9" "$ZG99"
fi
# Kursor zostaje na TYM SAMYM biegu po F8/F9 (run_cursor_for): panel (tytul i 'Kiedy' z data)
# jest ten sam przed i po -- inaczej przelaczenie widoku przenosiloby operatora na cudze zadanie.
panel_id() { printf '%s\n' "$1" | sed -n 2p | sed 's/^.*╗//'; printf '%s\n' "$1" | grep -oE 'Kiedy +20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1; }
ZCK="$(zkeys "^║ $KD +pve9 +wysyłka " $ZJARGS)"
ZC0="$(panel_id "$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys "$ZCK" --width 200 --height 60 2>&1)")"
ZC8="$(panel_id "$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys "${ZCK:+$ZCK,}F8" --width 200 --height 60 2>&1)")"
ZC9="$(panel_id "$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys "${ZCK:+$ZCK,}F9" --width 200 --height 60 2>&1)")"
if [ -n "$ZC0" ] && has "$ZC0" 'Kiedy' && [ "$ZC0" = "$ZC8" ] && [ "$ZC0" = "$ZC9" ]; then
    ok "zadania: po F8 i po F9 kursor zostaje na tym samym biegu (ten sam panel: tytul i termin)"
else
    bad "zadania: kursor po F8/F9" "przed: $ZC0" "F8: $ZC8" "F9: $ZC9"
fi

# ============================================================================
# U96 Dane biegu, U92 Enter na biegu, U98 odstep przed grupa panelu, U99 cron_words
# ============================================================================
# Fikstura: jedno zadanie (sync-test, dataset a, pull) z DWIEMA liniami crona o roznych
# etykietach ("hourly backup" i "extra backup"), dwa wykonane biegi linii pierwszej
# (koniec NOW-7200 i NOW-3600) i trzy migawki rodziny na LOKALNYM celu:
#   written 999999 sprzed poprzedniego biegu (NOW-9000)  -- nie wchodzi do drugiego biegu
#   written 1024   miedzy biegami (NOW-5000)             -- wchodzi
#   written 2048   o koncu biegu (NOW-3600)              -- wchodzi
# Dane drugiego biegu = 1024 + 2048 = 3072 B = 3.0K (hbytes_short).
UWD="$(mktemp -d)"
UWT="$("$PY" - "$FIX/jobs-group.json" "$UWD" "$NOW" <<'PYEOF'
import datetime, json, sys, time
gj, d, now = sys.argv[1], sys.argv[2], int(sys.argv[3])
j = json.load(open(gj, encoding="utf-8"))
a = [x for x in j["jobs"] if x["scope"].endswith("/lab/a")][0]
ds = a["scope"]
a["cron_lines"] = [
    '5 * * * * /x/zfs-job.sh "pve20 hourly backup (sync-test-a)" -- /x/snapget.sh -m "automated_hourly_" -L own-line "%s" ""' % a["other_end"],
    '5 * * * * /x/zfs-job.sh "pve20 extra backup (sync-test-a)" -- /x/snapget.sh -m "automated_hourly_" -L second-line "%s" ""' % a["other_end"]]
json.dump(j, open(d + "/jobs.json", "w", encoding="utf-8"))
def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone(datetime.timedelta(hours=2))).isoformat()
lbl = "hourly backup (sync-test-a)"
runs = [{"label": lbl, "start": iso(now - 7230), "end": iso(now - 7200), "rc": 0, "error": ""},
        {"label": lbl, "start": iso(now - 3630), "end": iso(now - 3600), "rc": 0, "error": ""}]
snaps = [{"name": ds + "@automated_hourly_old", "creation": now - 9000, "written": 999999},
         {"name": ds + "@automated_hourly_s1", "creation": now - 5000, "written": 1024},
         {"name": ds + "@automated_hourly_s2", "creation": now - 3600, "written": 2048}]
json.dump({"window_days": 7, "runs": runs, "snaps": snaps, "jobs": [], "events": [], "datasets": [], "volume": []},
          open(d + "/stats.json", "w", encoding="utf-8"))
print(time.strftime("%d.%m %H:%M", time.localtime(now - 3600)))
print(time.strftime("%d.%m %H:%M", time.localtime(now - 7200)))
PYEOF
)"
UWT="$(printf '%s\n' "$UWT" | tr -d '\r')"
UWT0="$(printf '%s\n' "$UWT" | sed -n 2p)"; UWT="$(printf '%s\n' "$UWT" | sed -n 1p)"
UWA="--status $FIX/status-group.json --jobs $UWD/jobs.json --monitors $FIX/monitors-group.json --stats $UWD/stats.json"
UWR="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $UWA --screen zadania --width 200 --height 400 2>&1)"
UWL="$(lst "$UWR")"
# (a) kolumna Dane: wykonany bieg = suma written migawek rodziny na celu miedzy biegami (3.0K); stara
# migawka 999999 (976.6K) liczy sie TYLKO poprzedniemu biegowi, nie drugiemu; nadchodzace biegi tej
# samej linii: '-'. Dolna zakladka: Źródło | Cel | Dane (bez Wynik). Na starym kodzie lista nie miala
# kolumny Dane, a pole snaps bylo ignorowane.
if [ -n "$UWT" ] && [ -n "$UWT0" ] && hasE "$UWR" '^║ Kiedy +Relacja +Co +Wynik +Czas +Dane' \
   && hasE "$UWL" "^║ $UWT +sync-test +pobranie .* OK +[0-9]+ [a-z]+ +3\.0K *\$" \
   && hasE "$UWL" "^║ $UWT0 +sync-test +pobranie .* OK +[0-9]+ [a-z]+ +977K *\$" \
   && hasE "$UWL" "^║ $KD +sync-test +pobranie .* nadchodzący +- +- *\$" \
   && hasE "$UWR" '║ Źródło +Cel +Dane' && ! hasE "$UWR" '║ Źródło +Cel +Wynik'; then
    ok "przebiegi U96/U97: kolumna Dane -- drugi bieg 3.0K (suma written migawek rodziny na celu miedzy biegami), pierwszy 977K (stara migawka 999999 B, hbytes_short), nadchodzacy '-'; dolna zakladka Źródło/Cel/Dane"
else
    bad "przebiegi U96: kolumna Dane" "kiedy: $UWT / $UWT0" "$(printf '%s\n' "$UWL" | grep -E '^║ (Kiedy|[0-9]{2}\.[0-9]{2}) ' | head -6)" "$(printf '%s\n' "$UWR" | grep -E 'Źródło')"
fi
# (b) Enter na wykonanym biegu: okno ma TYLKO linie crona tego biegu (etykieta 'hourly backup'), nie
# druga linie tego samego zadania ('extra backup'); okno relacji (F3) ma obie -- kontrola pozytywna.
UWK="$(zkeys "^║ $UWT +sync-test +pobranie " $UWA)"; UWKRC=$?
UWW="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $UWA --screen zadania --keys "${UWK:+$UWK,}enter" --width 200 --height 200 2>&1)"
UWF="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $UWA --screen relacje --keys enter,right --width 200 --height 300 2>&1)
$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $UWA --screen relacje --keys down,enter,right --width 200 --height 300 2>&1)"
if [ "$UWKRC" -eq 0 ] && has "$UWW" '── CRON ' && has "$UWW" 'own-line' && ! has "$UWW" 'second-line' \
   && has "$UWF" 'own-line' && has "$UWF" 'second-line'; then
    ok "przebiegi U92: Enter na biegu -- okno z linia crona TEGO biegu (own-line), bez drugiej linii zadania (second-line); okno relacji na F3 ma obie"
else
    bad "przebiegi U92: Enter na biegu" "klawisze: '$UWK' rc=$UWKRC" "$(printf '%s\n' "$UWW" | grep -E 'CRON|own-line|second-line')" "F3: $(printf '%s\n' "$UWF" | grep -cE 'own-line|second-line') linii"
fi
rm -rf "$UWD"
# (a2)(c)(d): funkcje wprost -- run_bytes (prune, cel zdalny, brak snaps, nadchodzacy), detail_kv (U98) i cron_words.
UWP="$("$PY" - "$TUI" <<'PYEOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
ch = m.Chars(False)
class D: pass
d = D(); T = 1000000
d.stats = {"snaps": [{"name": "hdd/t@automated_hourly_1", "creation": T - 10, "written": 1024}]}
j = {"section_kind": "dataset", "direction": "pull", "scope": "hdd/t", "other_end": "u@h:hdd/s", "prefix": "automated_hourly_"}
def dane(task, job, past=True, data=d):
    r = {"kind": "run", "past": past, "at": T, "end": T, "start": T - 30, "item": {"task": task}, "items": [], "jobs": [job]}
    v = m.run_bytes(r, data)
    return m.hbytes_short(v) if v is not None else "-"
d2 = D(); d2.stats = {}
print("pull=" + dane("pobranie", j))
print("local=" + dane("kopia", dict(j, direction="local", scope="hdd/s", other_end="hdd/t")))
print("prune=" + dane("lokalny prune", dict(j, section_kind="prune", direction="prune")))
print("upcoming=" + dane("pobranie", j, past=False))
print("remote=" + dane("wysyłka", dict(j, direction="push", scope="hdd/t", other_end="u@h:remote/ds")))
print("nosnaps=" + dane("pobranie", j, data=d2))
out = m.detail_kv(ch, [m.group(ch, u"Pierwsza"), (u"k1", u"v1"), m.group(ch, u"Druga"), (u"k2", u"v2"), m.group(ch, u"Trzecia"), (u"k3", u"v3")], 60)
ix = lambda w: [i for i, l in enumerate(out) if l.endswith(w)][0]
print("kv_first=%d" % ix("Pierwsza"))
print("kv_gap2=%s" % (out[ix("Druga") - 1] == "" and out[ix("Druga") - 2] != ""))
print("kv_gap3=%s" % (out[ix("Trzecia") - 1] == "" and out[ix("Trzecia") - 2] != ""))
print("cron=" + m.cron_words("30 21 * * 1-5"))
PYEOF
)"
UWP="$(printf '%s\n' "$UWP" | tr -d '\r')"
uwp() { printf '%s\n' "$UWP" | sed -n "s/^$1=//p"; }
if [ "$(uwp pull)" = "1.0K" ] && [ "$(uwp local)" = "1.0K" ] && [ "$(uwp prune)" = "-" ] && [ "$(uwp upcoming)" = "-" ] \
   && [ "$(uwp remote)" = "-" ] && [ "$(uwp nosnaps)" = "-" ]; then
    ok "przebiegi U96: run_bytes -- pobranie i kopia lokalna maja liczbe (1.0K), porzadki / bieg nadchodzacy / cel zdalny / brak pola snaps '-'"
else
    bad "przebiegi U96: run_bytes" "$UWP"
fi
if [ "$(uwp kv_first)" = "0" ] && [ "$(uwp kv_gap2)" = "True" ] && [ "$(uwp kv_gap3)" = "True" ]; then
    ok "panele U98: detail_kv -- pusta linia przed kazdym naglowkiem grupy, ale nie przed pierwszym (na samej gorze)"
else
    bad "panele U98: pusta linia przed grupa" "$UWP"
fi
if [ "$(uwp cron)" = "w dni pn-pt 21:30" ]; then
    ok "cron_words: '30 21 * * 1-5' -> 'w dni pn-pt 21:30' (U99)"
else
    bad "cron_words: dni tygodnia slowami" "$UWP"
fi

# ============================================================================
# R4-3/R4-5: co najmniej dwie spacje miedzy kolumnami; kiedy wszystkie sie
# mieszcza, zapas idzie w odstepy, a nie w pustke po prawej (zrzut wlasciciela
# z pve11 przy ~190 kolumnach). Fikstura hostA: 5 kolumn Przebiegow (Kiedy, Relacja,
# Co, Wynik, Czas); przy 260 lista ma 60% szerokosci.
R45N="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 100 2>&1 | sed -n 3p)"
R45W="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 260 2>&1 | sed -n 3p)"
_r45="${R45N%%║│*}"
if printf '%s' "$R45N" | grep -qE 'Kiedy {2,}Relacja {2,}[CW]' && ! printf '%s' "${_r45#║ }" | grep -qE '[^ ] [A-ZŁŚ][a-zęąśłó]' \
   && printf '%s' "$R45W" | grep -qE 'Kiedy {3,}Relacja {3,}Co {3,}Wynik'; then
    ok "zadania: odstep miedzy kolumnami >= 2 spacje; przy szerokiej liscie zapas rozlozony na odstepy (R4-3, R4-5)"
else
    bad "zadania: odstepy kolumn" "$R45N" "$R45W"
fi
# SYNCHRO: "<>" nie "<" (rekord mowi, linia crona nie umie) + F2 GRUPOWANIE
# ============================================================================
# UWAGA 4 (wlasciciel, 2026-09-24): szczebel plaski (pobranie + porzadki w JEDNEJ sekcji)
# mial w F2 tylko "pobranie". Porzadki z WLASNEJ linii zadania (tag "(sx-a)"), a linia
# porzadkow sasiedniego datasetu z tego samego bloku ("(sx-b)", inny harmonogram) nie wchodzi.
FP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs-flatprune.json" --monitors "$FIX/monitors-group.json" --screen zadania --width 200 --height 400 2>&1)"
FPARGS="--jobs $FIX/jobs-flatprune.json --monitors $FIX/monitors-group.json"
FPD="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $FPARGS --screen zadania --keys "$(zkeys "^║ $KD +sx +lokalny prune " $FPARGS)" --width 200 --height 60 2>&1)"
# F2 Przebiegi: kazdy bieg to wiersz, wiec porzadkow jest tyle, ile ich terminow w oknie 6 h.
# "Tylko wlasne" znaczy teraz: WSZYSTKIE wiersze 'lokalny prune' tej relacji maja minute
# wlasnej linii delsnaps (:21), zadnego z minuta cudzej (:17) -- i panel wiersza to wlasny
# harmonogram i retencja.
FPMIN="$(printf '%s\n' "$FP" | grep -E "^║ $KD +sx +lokalny prune " | sed -E 's/^║ [0-9]{2}\.[0-9]{2} [0-9]{2}:([0-9]{2}) .*/\1/' | sort -u | tr '\n' ' ')"
if hasE "$FP" "^║ $KD +sx +lokalny prune " && hasE "$FPD" 'Kiedy +co godzinę \(:21\)' && hasE "$FPD" 'Trzyma +168 godz\.' && ! hasE "$FPD" 'Kiedy +co godzinę \(:17\)' \
   && [ "$FPMIN" = "21 " ]; then
    ok "zadania: szczebel plaski pokazuje WLASNE porzadki (harmonogram z jego linii delsnaps), bez cudzych z bloku (uwaga 4: pve9-synchro)"
else
    bad "zadania: porzadki szczebla plaskiego (uwaga 4)" "minuty wierszy 'lokalny prune': '$FPMIN'" "$FP"
fi
# Panel wiersza 'lokalny prune' ma statystyki WLASNEJ linii delsnaps (przejscie GUI pve10,
# 2026-10-28): wiersz byl dorabiany z srow=None i panel mowil "brak biegow w dzienniku",
# choc lista obok pokazywala te biegi.
FPSARGS="$FPARGS --stats $FIX/stats-flatprune.json"
FPS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $FPSARGS --screen zadania --keys "$(zkeys "^║ $KD +sx +lokalny prune " $FPSARGS)" --width 200 --height 60 2>&1)"
if hasE "$FPS" 'Wywołania +144, błędów 1' && hasE "$FPS" 'ostatni 3s / średni 2s / maks\. 1m11s' && ! hasE "$FPS" 'brak biegów w dzienniku'; then
    ok "zadania: panel 'lokalny prune' liczy biegi wlasnej linii delsnaps, nie 'brak biegow w dzienniku'"
else
    bad "zadania: statystyki wiersza 'lokalny prune'" "$FPS"
fi
# U112 (wlasciciel 2026-10-28, symulacja A): udane biegi jednej linii prune zwijaja sie w JEDEN
# wiersz "x N" w miejscu ostatniego, bieg z bledem zostaje osobno, z nadchodzacych prune tylko
# najblizszy. Transfer obok (pobranie) bez zmian: kazdy bieg osobno.
FPF="$(mktemp)"
"$PY" - "$FIX/stats-flatprune.json" "$NOW" > "$FPF" <<'PYEOF'
import json, sys, time
d = json.load(open(sys.argv[1], encoding="utf-8")); now = int(sys.argv[2])
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(t))
lbl = "profile__p__flat_hourly prune (sx-a)"
d["runs"] = [{"label": lbl, "start": iso(now - 3600 * k - 40), "end": iso(now - 3600 * k - 30), "rc": 1 if k == 5 else 0,
              "error": "delsnaps: test" if k == 5 else ""} for k in range(11, 0, -1)]
print(json.dumps(d))
PYEOF
FPZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $FPARGS --stats "$FPF" --screen zadania --keys "" --width 200 --height 200 2>&1)"
FPZD="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $FPARGS --stats "$FPF" --screen zadania --keys "$(zkeys "lokalny prune .*×10" $FPARGS --stats "$FPF")" --width 200 --height 60 2>&1)"
# 80 kolumn: kolumna Co znika, "xN" stoi w Wyniku, wiec zwiniecie dalej widac (kampania 2026-10-28).
FPZ80="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $FPARGS --stats "$FPF" --screen zadania --keys "" --width 80 --height 200 2>&1)"
FZP="$(lst "$FPZ" | grep -cE "lokalny prune .*(OK|BŁĄD)")"; FZN="$(lst "$FPZ" | grep -cE "lokalny prune .*nadchodzący")"
FZT="$(lst "$FPZ" | grep -cE "pobranie .*nadchodzący")"
if [ "$FZP" = 2 ] && hasE "$FPZ" "lokalny prune .* OK ×10 \(błędy: 1\)" && hasE "$FPZ" "lokalny prune .* BŁĄD rc=1" \
   && [ "$FZN" = 1 ] && [ "$FZT" -gt 1 ] && hasE "$FPZD" "Zwinięte +udane biegi: 10, od" && hasE "$(lst "$FPZ80")" "OK ×10"; then
    ok "zadania U112: udane prune jednej linii w jednym wierszu x10 (bledy osobno), z nadchodzacych prune tylko najblizszy, pobrania bez zmian"
else
    bad "zadania U112: zwijanie prune" "wykonane prune: $FZP (2), nadchodzace prune: $FZN (1), nadchodzace pobrania: $FZT (>1)" "$(lst "$FPZ" | grep -E 'prune|pobranie' | head -20)"
fi
rm -f "$FPF"
# Atrapa relacji: sync-test ma TRZY linie crona identyczne poza zakresem (a/b/c,
# ten sam harmonogram) plus czwarta pod INNYM harmonogramem (d) -- ta czwarta
# NIE ma sie zlaczyc. backup-test to relacja BEZ rekordu synchro (mode
# nieobecny), zeby pokazac, ze "<" zostaje, kiedy rekord nie mowi "sync".
GJ="$FIX/jobs-group.json"; GS="$FIX/status-group.json"; GM="$FIX/monitors-group.json"
G="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --width 200 --height 400 2>&1)"
GR="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen relacje --width 200 2>&1)"
# F2 Przebiegi: wiersz to BIEG jednej LINII CRONA. a, b, c maja kazde swoja linie (wlasna
# etykiete) pod tym samym harmonogramem (:05), d inny (:10): wierszy :05 jest trzy razy tyle
# co :10 -- kazda linia ma swoj bieg i swoj wynik, nic sie nie zlewa. Panel wiersza a: kierunek
# synchro '<>' (z rekordu, choc linia crona to pull) i ZRODLO/CEL tego jednego datasetu.
GN="$(lst "$G" | grep -E "^║ $KD +sync-test +pobranie " | sed -E 's/^║ [0-9]{2}\.[0-9]{2} [0-9]{2}:([0-9]{2}) .*/\1/' | sort | uniq -c | sed -E 's/^ *//' | tr '\n' ',')"
GN1="$(printf '%s' "$GN" | cut -d, -f1)"; GN2="$(printf '%s' "$GN" | cut -d, -f2)"
GZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --width 200 --height 60 2>&1)"
if [ "$(printf '%s' "$GN" | tr -cd ',' | wc -c | tr -d ' ')" -eq 2 ] && [ "${GN1#* }" = "05" ] && [ "${GN2#* }" = "10" ] \
    && [ "${GN1%% *}" -eq $(( ${GN2%% *} * 3 )) ] && [ "${GN2%% *}" -ge 1 ] \
    && hasE "$G" "^║ $KD +backup-test +pobranie +standard_hourly: e " \
    && hasE "$GZ" 'Kierunek +pve20 ↔ sync-test' && hasE "$GZ" 'Źródło +sync-test:hdd/lab/a'; then
    ok "zadania: F2 -- kazda linia crona ma swoj bieg (a/b/c pod :05 = 3x wierszy d pod :10); panel: synchro '<>' mimo ze linia to pull, zrodlo tego datasetu"
else
    bad "zadania: F2 grupowanie i symbol synchro" "minuty wierszy sync-test (liczba minuta): $GN" "$GZ"
fi
# JEDNA linia crona z kilkoma datasetami (pve2 2026-10-27: subvol-103 + ROOT/pve-1 w jednym
# snapget) to JEDEN bieg: wariant fikstury, w ktorym b i c niosa etykiete linii a. Panel ma
# wtedy JEDNA linie 'Zakres' z liczba i wszystkimi trzema datasetami (R3-3), a przy 30
# wierszach terminala 'Kiedy' (harmonogram) dalej widac.
GJ1="$(mktemp)"
"$PY" - "$GJ" "$GJ1" <<'PYEOF'
import json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
abc = [x for x in j["jobs"] if x["scope"].rsplit("/", 1)[-1] in ("a", "b", "c")]
line = '%s /x/zfs-job.sh "pve20 hourly backup (sync-test-all)" -- /x/snapget.sh -m "automated_hourly_" "%s" ""' % (
    abc[0]["schedule"], ",".join(x["other_end"] for x in abc))
for x in abc:
    x["cron_lines"] = [line]
json.dump(j, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
G1="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ1" --monitors "$GM" --screen zadania --width 200 --height 400 2>&1)"
G1N="$(lst "$G1" | grep -E "^║ $KD +sync-test +pobranie " | sed -E 's/^║ [0-9]{2}\.[0-9]{2} [0-9]{2}:([0-9]{2}) .*/\1/' | sort | uniq -c | sed -E 's/^ *//' | tr '\n' ',')"
G1A="$(printf '%s' "$G1N" | cut -d, -f1)"; G1B="$(printf '%s' "$G1N" | cut -d, -f2)"
if grep -q 'sync-test-all' "$GJ1" && [ "${G1A%% *}" = "${G1B%% *}" ] \
    && has "$G1" '3 datasetów w hdd/backups/192.168.28.50/hdd/lab: a, b, c' && ! has "$G1" 'zakres 1' && ! has "$G1" 'zakres 2'; then
    ok "zadania: jedna linia crona z trzema datasetami to jeden bieg; panel -- JEDNA linia 'zakres' z liczba i wszystkimi trzema (R3-3)"
else
    bad "zadania: panel grupy" "minuty: $G1N" "$G1"
fi
# U26 (wlasciciel 2026-10-19, zrzut: lustro po F7 dalej "stare" w kazdym wierszu): jeden
# monitor relacji pilnuje 4 datasetow, CRITICAL przez jeden (c). Para bierze linie SWOJEGO
# datasetu z reason; relacja jako calosc dalej "stare". Reason w PRAWDZIWYM ksztalcie (pve10
# 2026-10-20): check-snap-age pisze linie tylko dla datasetow nie-OK -- brak linii = OK (E94).
# Kontrola na #631 (zalozyl linie OK): 4 x "stare".
GRP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$FIX/monitors-group-perds.json" --screen relacje --width 200 2>&1)"
if hasE "$GRP" 'hdd/lab/a +aktualne' && hasE "$GRP" 'hdd/lab/b +aktualne' && hasE "$GRP" 'hdd/lab/c +stare' \
   && hasE "$GRP" 'hdd/lab/d +aktualne' && hasE "$GRP" '^║ sync-test .* stare'; then
    ok "relacje: U26 -- monitor wielu datasetow: para ma werdykt swojego datasetu (1 stara, 3 aktualne), relacja najgorszy"
else
    bad "relacje: U26 werdykt per dataset" "$(printf '%s\n' "$GRP" | grep -E 'hdd/lab/[a-d] |^║ sync-test')"
fi
# Kampania 2026-10-19: kolektor za VPN, adres zmieniony (active_endpoint 10.98.0.2) --
# kolumna Kierunek na F3 pokazywala dalej stary peer_host. Kontrola: bez zmiany adresu -- jak bylo.
GSV="$(mktemp)"; sed 's/"active_endpoint":"192.168.28.60:22"/"active_endpoint":"10.98.0.2:22"/' "$GS" > "$GSV"
GHV="$(mktemp)"; printf '10.98.0.2 pve9-vpn\n192.168.28.60 pve9-lan\n' > "$GHV"
GRV="$(ZFS_TUI_HOSTS="$GHV" "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GSV" --jobs "$GJ" --monitors "$GM" --screen relacje --width 200 2>&1)"
if grep -q '10.98.0.2:22' "$GSV" && hasE "$GRV" '^║ backup-test .*pve9-vpn → pve20 ' && ! hasE "$GRV" '^║ backup-test .*pve9-lan' \
   && hasE "$GR" '^║ backup-test .*backup-test → pve20 '; then
    ok "relacje: Kierunek pokazuje adres, przez ktory relacja chodzi teraz (po zmianie adresu: 10.98.0.2, nie stary peer_host)"
else
    bad "relacje: Kierunek po zmianie adresu" "$(printf '%s\n' "$GRV" | grep 'backup-test' | head -2)" "$(printf '%s\n' "$GR" | grep 'backup-test' | head -1)"
fi
rm -f "$GSV" "$GHV"
# R3-3: przy malym terminalu (30 wierszy) 'harmonogram' MA byc widoczny, mimo
# ze zakres jednej linii z trzema datasetami jest jedna dluga linia.
G30="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ1" --monitors "$GM" --screen zadania --width 200 --height 30 2>&1)"
if has "$G30" '3 datasetów w' && hasE "$G30" 'Kiedy +co godzinę'; then
    ok "zadania: panel grupy przy --height 30 -- 'Zakres' jedna linia, 'Kiedy' wciaz widoczne"
else
    bad "zadania: panel grupy przy malym terminalu" "$G30"
fi
rm -f "$GJ1"
GBK="$(zkeys "^║ $KD +backup-test " --status "$GS" --jobs "$GJ" --monitors "$GM")"
GB_="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --keys "$GBK" --width 200 2>&1)"
if [ -n "$GBK" ] && hasE "$GB_" 'Kierunek +backup-test → pve20' && ! hasE "$GB_" 'Kierunek +pve20 ↔'; then
    ok "zadania: panel kierunku backupu ma '<', synchro '<>' (rekord wygrywa z linia crona)"
else
    bad "zadania: panel kierunku synchro" "klawisze: $GBK" "$GB_"
fi
if hasE "$GR" '^║ sync-test +lustro +pve20 ↔ sync-test ' && hasE "$GR" '^║ backup-test +backup +backup-test → pve20 '; then
    ok "relacje: F3 tez rysuje '<>' dla synchro (z rekordu, nie z linii crona) i '<' dla backupu"
else
    bad "relacje: symbol synchro na F3" "$GR"
fi
# BLAD BIEGU I WYRZUCENIA (2026-10-08, wlasciciel "rob 1 i 2"): monitor patrzy
# tylko na wiek kopii -- na pve10 lustro, ktore odmowilo pobrania (dzialajacy
# gosc 901), bylo "aktualne" na F2 i F3. Ostatni bieg z rc != 0 (poza 75 =
# pominiety przez blokade) daje "błąd biegu"; to, co bieg wyrzucil (P-0), panel.
GEJ="$(mktemp)"; GES="$(mktemp)"
"$PY" - "$GJ" "$GEJ" "$GES" "$NOW" <<'PYEOF'
import datetime, json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
# Real shape (pve10, 2026-10-08): every job of a block carries the WHOLE block's
# lines, and a pull line quotes its SOURCE (the job's other_end), not the scope.
# Matched on the scope alone, every job took the first line's label -- the
# failure of 'b' was then read from 'a' and the row stayed "aktualne".
block = {}
for x in j["jobs"]:
    leaf = x["scope"].rsplit("/", 1)[-1]
    block.setdefault(x["label"], []).append('%s /x/zfs-job.sh "pve20 hourly backup (%s-%s)" -- /x/snapget.sh -m "automated_hourly_" -M "%s" ""'
                                            % (x["schedule"], x["label"], leaf, x["other_end"]))
for x in j["jobs"]:
    x["cron_lines"] = list(block[x["label"]])
json.dump(j, open(sys.argv[2], "w", encoding="utf-8"))
def row(leaf, rc):
    return {"label": "hourly backup (sync-test-%s)" % leaf, "runs": 5, "failures": 1 if rc else 0, "avg_s": 3, "max_s": 7,
            "total_s": 15, "last_s": 2, "last_rc": rc, "last_at": "2026-09-08 13:48"}
# F2 PRZEBIEGI: wykonane biegi (job-stats --runs, z dziennika crona) w oknie 12 h przed NOW.
# Wiersz F2 ma etykiete PIERWSZEJ linii zadania (a/b/c maja ten sam harmonogram i sa jednym
# zadaniem, d -- drugim); bieg a/b/c jest wiec zapisany pod etykieta pierwszego z nich -- jak
# prawdziwa wspolna linia (pve2: jedna etykieta, jeden rc, tekst bledu nazywa dataset).
# Blad: odmowa na 'b' (rc=1); drugie zadanie (d) -- pominiete przez blokade (rc=75).
now = int(sys.argv[4])
def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone(datetime.timedelta(hours=2))).isoformat()
lead = {}
for x in j["jobs"]:
    if x["label"] == "sync-test":
        lead.setdefault(x["schedule"], x["scope"].rsplit("/", 1)[-1])
grp = {}
for x in j["jobs"]:
    if x["label"] == "sync-test":
        grp[x["scope"].rsplit("/", 1)[-1]] = lead[x["schedule"]]
runs = [{"label": "hourly backup (sync-test-%s)" % grp["b"], "start": iso(now - 3630), "end": iso(now - 3600), "rc": 1,
         "error": "Refusing 'hdd/lab/b': it is the disk of guest 901, which is currently RUNNING."},
        {"label": "hourly backup (sync-test-%s)" % grp["d"], "start": iso(now - 1830), "end": iso(now - 1800), "rc": 75,
         "error": ""}]
json.dump({"window_days": 7, "runs": runs, "jobs": [row("a", 0), row("b", 1), row("c", 0), row("d", 75)],
           "events": [{"label": "hourly backup (sync-test-b)", "discard_at": "", "discard": "", "error_at": "2026-09-08 13:48",
                       "error": "Refusing 'hdd/lab/b': it is the disk of guest 901, which is currently RUNNING."},
                      {"label": "hourly backup (sync-test-a)", "discard_at": "2026-09-08 12:16",
                       "discard": "hdd/lab/a: 1 snapshot(s) after @s1 that the source no longer has: p0manual",
                       "error_at": "", "error": ""}],
           "datasets": [], "volume": []}, open(sys.argv[3], "w", encoding="utf-8"))
PYEOF
GE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen zadania --width 200 --height 50 2>&1)"
# F2 PRZEBIEGI: slowa 'błąd biegu' w liscie juz nie ma (to byl werdykt zadania; jest na F3, test
# 'relacje: relacja z nieudanym ostatnim biegiem' nizej). Lista mowi o KONKRETNYM biegu: wykonany
# bieg z rc=1 to wiersz "BŁĄD rc=1", rc=75 (blokada) to "pominięty" -- nie blad, inna relacja
# bez biegow w oknie ma tylko wiersze nadchodzace; kreska "teraz" dzieli wykonane od nadchodzacych.
GEK="$(zkeys "^║ $KD +sync-test +.*BŁĄD rc=1" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES")"
GEP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen zadania --keys "$GEK" --width 200 --height 60 2>&1)"
GEL="$(lst "$GE")"
if [ "$(printf '%s\n' "$GEL" | grep -cE "^║ $KD +sync-test .*BŁĄD rc=1")" = 1 ] && ! hasE "$GEL" "^║ $KD +sync-test .*BŁĄD rc=75" \
   && [ "$(printf '%s\n' "$GEL" | grep -cE "^║ $KD +sync-test .*pominięty")" = 1 ] && ! hasE "$GEL" '^║ [0-9. :]+ +backup-test .*BŁĄD' \
   && hasE "$GEL" '^║ ── teraz [0-9]{2}:[0-9]{2}' \
   && hasE "$GEP" 'Wynik +BŁĄD rc=1' && hasE "$GEP" 'Powód +Refusing' && has "$GEP" '── Ten bieg'; then
    ok "zadania: wykonany bieg z rc=1 to wiersz 'BŁĄD rc=1' z powodem w panelu ('Ten bieg'); rc=75 (blokada) to 'pominięty', nie blad; inna relacja bez bledu; kreska 'teraz' dzieli wykonane od nadchodzacych"
else
    bad "zadania: błąd biegu na F2" "$(printf '%s\n' "$GE" | grep -E '^║ (sync|backup)-test|teraz' | head -8)" "$(printf '%s\n' "$GEP" | grep -E 'Wynik|Powód|Ten bieg')"
fi
if hasE "$GE" 'Błąd +2026-09-08 13:48 +[^ ]*/lab/b +rc=1' && has "$GE" 'Refusing' \
   && hasE "$GE" 'Wyrzucono +2026-09-08 12:16  hdd/lab/a: 1 snapshot' \
   && has "$GE" 'błędów 1   w 3 zadaniach'; then
    ok "zadania: panel wiersza mowi, ktory dataset i dlaczego (blad z dziennika) oraz co bieg wyrzucil z kopii"
else
    bad "zadania: panel błąd/wyrzucono" "$(printf '%s\n' "$GE" | grep -E 'Błąd|Wyrzuc|błędów')"
fi
# PRZEBIEGI: WIERSZE TYLKO DO CZYTANIA. Kreska "── teraz HH:MM" (i w grupach naglowek
# "▸ NAZWA") nie jest biegiem: kursor jej nie zaznacza (panel zawsze mowi o biegu: 'Ten bieg'
# albo 'Nadchodzący bieg'), a F7 na wykonanym biegu niczego nie uruchamia. Fikstura: jeden
# wykonany bieg OK (etykieta pierwszej linii sync-test), reszta nadchodzaca; stan jak po
# pierwszej godzinie dzialania -- [0] wykonany OK, [1] kreska, [2] pierwszy nadchodzacy.
PRS="$(mktemp)"
"$PY" - "$GES" "$PRS" "$NOW" "$GEJ" <<'PYEOF'
import datetime, json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
now = int(sys.argv[3])
j = json.load(open(sys.argv[4], encoding="utf-8"))
first = [x for x in j["jobs"] if x["label"] == "sync-test"][0]
def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone(datetime.timedelta(hours=2))).isoformat()
st["runs"] = [{"label": "hourly backup (sync-test-%s)" % first["scope"].rsplit("/", 1)[-1],
               "start": iso(now - 5430), "end": iso(now - 5400), "rc": 0, "error": ""}]
json.dump(st, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
PRARGS="--status $GS --jobs $GEJ --monitors $GM --stats $PRS"
prz() {   # <klawisze> [extra] -> ekran F2
    # "home": F2 startuje przy "teraz"; te przypadki licza klawisze od gory listy
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PRARGS --screen zadania --keys "home${1:+,$1}" --width 200 --height 60 "${@:2}" 2>&1
}
PR0="$(prz "")"
PR0L="$(lst "$PR0")"
PRL="$(printf '%s\n' "$PR0L" | grep -nE "^║ ($KD|── teraz)" | head -3 | cut -d: -f1 | tr '\n' ' ')"
set -- $PRL
if hasE "$PR0L" "^║ $KD +sync-test +pobranie .* OK( |$)" && hasE "$PR0L" '^║ ── teraz [0-9]{2}:[0-9]{2}' && [ $# -ge 3 ] \
   && printf '%s\n' "$PR0L" | sed -n "${1}p" | grep -qE ' OK( |$)' && printf '%s\n' "$PR0L" | sed -n "${2}p" | grep -q 'teraz' \
   && printf '%s\n' "$PR0L" | sed -n "${3}p" | grep -q 'nadchodzący'; then
    ok "przebiegi: wiersze tylko do czytania (a) -- kreska 'teraz' stoi miedzy wykonanym biegiem OK a pierwszym nadchodzacym"
else
    bad "przebiegi: kreska 'teraz'" "linie: $PRL" "$PR0"
fi
PRD="$(prz down)"; PRU="$(prz down,up)"; PRUU="$(prz down,down,up,up)"; PRUP="$(prz up)"
# 'down' z wykonanego przeskakuje kreske na pierwszy nadchodzacy; 'up' z niego wraca na wykonany
# (nie na kreske -- na kresce panel by zniknal); 'up' w gore od zerowego wiersza zostaje.
if has "$PRD" 'Nadchodzący bieg' && ! has "$PRD" '── Ten bieg' \
   && has "$PRU" '── Ten bieg' && ! has "$PRU" 'Nadchodzący bieg' \
   && has "$PRUU" '── Ten bieg' && ! has "$PRUU" 'Nadchodzący bieg' \
   && has "$PRUP" '── Ten bieg'; then
    ok "przebiegi: wiersze tylko do czytania (b) -- kursor nie staje na kresce 'teraz': down przeskakuje ja, up z pierwszego nadchodzacego wraca na wykonany (panel zawsze o biegu)"
else
    bad "przebiegi: kursor na kresce" "down: $(printf '%s\n' "$PRD" | grep -E 'Ten bieg|Nadchodzący')" "down,up: $(printf '%s\n' "$PRU" | grep -E 'Ten bieg|Nadchodzący')" "down,down,up,up: $(printf '%s\n' "$PRUU" | grep -E 'Ten bieg|Nadchodzący')"
fi
PXL="$(mktemp)"; : > "$PXL"
# Start BEZ klawiszy: kursor przy "teraz" -- na najblizszym nadchodzacym biegu, nie na
# najstarszym wykonanym (przejscie GUI pve10, 2026-10-28).
PRZS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PRARGS --screen zadania --keys "" --width 200 --height 60 2>&1)"
if hasE "$PRZS" 'Nadchodzący bieg' && ! hasE "$PRZS" '── Ten bieg'; then
    ok "przebiegi: F2 otwiera sie z kursorem przy 'teraz' (najblizszy nadchodzacy bieg)"
else
    bad "przebiegi: start kursora" "$(printf '%s\n' "$PRZS" | grep -E 'Ten bieg|Nadchodzący')"
fi
# Kursor na OSTATNIM wierszu okna, gdy nizej sa dalsze: wiersz byl zastepowany przez
# "... jeszcze N" i biegu z panelu nie bylo na liscie. Niska wysokosc, kursor przy "teraz":
# czas biegu z panelu (Kiedy RRRR-MM-DD GG:MM) musi stac na liscie.
PRM="$(mktemp)"
"$PY" - "$PRS" "$PRM" "$NOW" <<'PYEOF'
import datetime, json, sys
st = json.load(open(sys.argv[1], encoding="utf-8"))
now = int(sys.argv[3])
r0 = st["runs"][0]
def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone(datetime.timedelta(hours=2))).isoformat()
# 20 wykonanych biegow co 30 min wstecz: lista dluzsza niz okno przy --height 16
st["runs"] = [dict(r0, start=iso(now - 600 - 1800 * k - 30), end=iso(now - 600 - 1800 * k)) for k in range(20)]
json.dump(st, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
PRZH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" ${PRARGS%--stats*} --stats "$PRM" --screen zadania --keys "" --width 200 --height 16 2>&1)"
rm -f "$PRM"
PRZT="$(printf '%s\n' "$PRZH" | grep -oE 'Kiedy +[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1 | grep -oE '[0-9]{2}:[0-9]{2}$')"
if [ -n "$PRZT" ] && printf '%s\n' "$PRZH" | sed 's/║│.*//' | grep -qE "^║ [0-9]{2}\.[0-9]{2} $PRZT "; then
    ok "przebiegi: wiersz z kursorem widac na liscie i przy niskim oknie (nie zaslania go '... jeszcze N')"
else
    bad "przebiegi: wiersz kursora zasloniety" "czas z panelu: '$PRZT'" "$PRZH"
fi
PRF="$(prz F7 --exec-log "$PXL")"
PRF_LOG="$(cat "$PXL")"
PRG="$(prz down,F7 --exec-log "$PXL")"
if has "$PRF" 'ten bieg już był -- F7 uruchamia zadanie z wiersza nadchodzącego' && [ -z "$PRF_LOG" ] \
   && ! has "$PRG" 'ten bieg już był' && grep -q 'zfs-job.sh' "$PXL"; then
    ok "przebiegi: wiersze tylko do czytania (c) -- F7 na wykonanym biegu mowi 'ten bieg już był' i nic nie uruchamia; ten sam F7 na nadchodzacym uruchamia linie crona"
else
    bad "przebiegi: F7 na wykonanym biegu" "$(printf '%s\n' "$PRF" | tail -3)" "log: $(cat "$PXL")"
fi
rm -f "$PXL"
# F4 Z PRZEBIEGOW (U82, dwa panele): na wykonanym biegu F4 otwiera Kopie z kursorem na
# datasecie celu tego biegu i FOKUSEM W PRAWYM PANELU na najnowszej migawce nie nowszej niz
# koniec biegu; Enter oddaje terminal oknu browse z --snapshot=PELNA_NAZWA (bez --dataset=/--at=).
# Fikstura: wykonany bieg konczy sie o NOW-5400 (PRS), pierwszy wiersz listy; migawki celu
# (zfs-snapshots.json, dataset a..d pod 192.168.28.50) sa o 1788955201 (PO biegu, 11:20),
# 1788951601 (PRZED biegiem, 10:20) i wczesniejsza -- wybrana ma byc ta z 10:20, nie najnowsza.
# Na biegu NADCHODZACYM (down) nie ma chwili: fokus zostaje na liscie, Enter tylko go przenosi.
PZ="--zfs-tree $P10/zfs-tree.json --zfs-snapshots $P10/zfs-snapshots.json"
PKX="$(mktemp)"; : > "$PKX"
PK4="$(prz F4 --exec-log "$PKX" $PZ)"
PK4E="$(prz F4,enter --exec-log "$PKX" $PZ)"; PK4LOG="$(cat "$PKX")"
: > "$PKX"
PK4N="$(prz down,F4 --exec-log "$PKX" $PZ)"
PK4NE="$(prz down,F4,enter --exec-log "$PKX" $PZ)"; PK4NLOG="$(cat "$PKX")"
if has "$PK4" '╔═ Kopie na pve20' && hasE "$PK4" 'hdd/backups/192\.168\.28\.50/hdd/lab/[a-d]: \[Migawki\]' \
   && hasE "$PK4" 'Migawka +@automated_hourly_2026-09-09_10-20-01' && hasE "$PK4" 'Dataset +hdd/backups/192\.168\.28\.50/hdd/lab/[a-d]' && ! has "$PK4" 'Enter/Tab do migawek' \
   && printf '%s\n' "$PK4LOG" | grep -Eq "zfs-backup.sh'? browse sync-test --ask --snapshot=hdd/backups/192\.168\.28\.50/hdd/lab/[a-d]@automated_hourly_2026-09-09_10-20-01\$" \
   && ! printf '%s' "$PK4LOG" | grep -q -- '--at=' && ! printf '%s' "$PK4LOG" | grep -q -- '--dataset='; then
    ok "kopie: F4 na wykonanym biegu (F2) -- fokus w prawym panelu na najnowszej migawce nie nowszej niz koniec biegu (10:20, nie 11:20), Enter = browse REL --ask --snapshot=PELNA_NAZWA"
else
    bad "kopie: F4 z wykonanego biegu" "$(printf '%s\n' "$PK4" | grep -E 'Kopie na|zfs list|Migawka|Enter/Tab')" "log: $PK4LOG"
fi
if has "$PK4N" '╔═ Kopie na pve20' && hasE "$PK4N" 'hdd/backups/192\.168\.28\.50/hdd/lab/[a-d]: \[Migawki\]' && has "$PK4N" 'Enter/Tab do migawek' \
   && ! hasE "$PK4N" 'Migawka +@' && [ ! -s "$PKX" ] && [ -z "$PK4NLOG" ]; then
    ok "kopie: F4 na biegu nadchodzacym -- kursor na datasecie celu, fokus na LISCIE (nie ma chwili), Enter tylko przenosi fokus i niczego nie uruchamia"
else
    bad "kopie: F4 z nadchodzacego biegu" "$(printf '%s\n' "$PK4N" | grep -E 'Kopie na|zfs list|Migawka|Enter/Tab')" "log: $PK4NLOG"
fi
rm -f "$PKX"
# F8 chowa wykonane (bez kreski), drugi F8 je przywraca; kursor zostaje na TYM SAMYM biegu
# (run_cursor_for: ten sam bieg -- zadanie i chwila; wykonanego, ktory zniknal, zastepuje
# pierwszy nadchodzacy). F9 przeklada wiersze do grup, a bieg pod kursorem sie nie zmienia.
pr_when() { printf '%s\n' "$1" | grep -oE 'Kiedy +20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}' | head -1; }
PRH="$(prz F8)"; PRHH="$(prz down,F8)"; PRHR="$(prz down,F8,F8)"; PRN="$(prz down)"
PRG9="$(prz down,F9)"
PRHL="$(lst "$PRH")"; PRHRL="$(lst "$PRHR")"; PRG9L="$(lst "$PRG9")"
if ! hasE "$PRHL" "^║ $KD +sync-test +pobranie .* OK( |$)" && ! hasE "$PRHL" '^║ ── teraz' && has "$PRH" '-- tylko nadchodzące' && has "$PRH" 'Nadchodzący bieg' \
   && [ -n "$(pr_when "$PRN")" ] && [ "$(pr_when "$PRN")" = "$(pr_when "$PRH")" ] && [ "$(pr_when "$PRN")" = "$(pr_when "$PRHH")" ] \
   && [ "$(pr_when "$PRN")" = "$(pr_when "$PRHR")" ] && hasE "$PRHRL" "^║ $KD +sync-test +pobranie .* OK( |$)" && hasE "$PRHRL" '^║ ── teraz' \
   && [ "$(pr_when "$PRN")" = "$(pr_when "$PRG9")" ] && hasE "$PRG9L" '^║ ▸ sync-test' && hasE "$PRG9L" '^║ ── teraz'; then
    ok "przebiegi: F8 chowa wykonane i kreske, drugi F8 je przywraca; kursor zostaje na tym samym biegu po F8 i po F9 (grupa ma swoja kreske)"
else
    bad "przebiegi: F8/F9 i kursor" "bez F8: $(pr_when "$PRN")" "F8: $(pr_when "$PRH")" "down,F8: $(pr_when "$PRHH")" "down,F8,F8: $(pr_when "$PRHR")" "down,F9: $(pr_when "$PRG9")"
fi
rm -f "$PRS"
GER="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen relacje --width 200 2>&1)"
if hasE "$GER" '^║ sync-test .*błąd biegu' && ! hasE "$GER" '^║ backup-test .*błąd biegu'; then
    ok "relacje: relacja z nieudanym ostatnim biegiem jest na F3 'błąd biegu', nie 'aktualne'"
else
    bad "relacje: błąd biegu na F3" "$(printf '%s\n' "$GER" | grep -E '^║ (sync|backup)-test')"
fi
# U61 (kampania 2026-10-21): relacja "błąd biegu", panel "Ostatni bieg OK", wiersz datasetu
# "aktualne" -- trzy werdykty o tym samym. Teraz panel mowi BŁĄD i przyczyne (ktory dataset,
# dlaczego), a wiersz pary nieudanego zadania to "błąd biegu"; pary udanych zostaja "aktualne".
u61_ok=0; u61_dump=""
for u61k in "" down down,down; do
    U61="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen relacje --width 200 --height 60 --keys "$u61k" 2>&1)"
    has "$U61" 'Przyczyna' || continue
    u61_dump="$U61"
    if hasE "$U61" 'Ostatni bieg +BŁĄD +2026-09-08 13:48 +rc=1' && hasE "$U61" 'Przyczyna +[^ ]*b: Refusing' \
       && ! hasE "$U61" 'Ostatni bieg +OK' && printf '%s\n' "$U61" | grep 'lab/b' | grep -q 'błąd biegu' \
       && printf '%s\n' "$U61" | grep 'lab/c' | grep -vq 'błąd biegu'; then u61_ok=1; fi
    break
done
if [ "$u61_ok" -eq 1 ]; then
    ok "relacje U61: jeden werdykt -- panel 'Ostatni bieg BŁĄD ... rc=1' i 'Przyczyna: b: Refusing...', wiersz pary b 'błąd biegu', c bez bledu"
else
    bad "relacje U61: sprzeczne werdykty" "$(printf '%s\n' "$u61_dump" | grep -E 'Ostatni bieg|Przyczyna|lab/[abcd]' | head -10)"
fi
# ONE CRON LINE, SEVERAL DATASETS (pve2, 2026-10-27): subvol-103 and ROOT/pve-1 went in one
# snapget call, the refusal was on pve-1, and the panel said "Przyczyna subvol-103: ..." with
# "(+3)". The shared failure counts once and names a dataset only when the error text does.
GSJ="$(mktemp)"; GSS="$(mktemp)"
"$PY" - "$GJ" "$GSJ" "$GSS" <<'PYEOF'
import json, sys
j = json.load(open(sys.argv[1], encoding="utf-8"))
mine = [x for x in j["jobs"] if x["label"] == "sync-test"]
line = '%s /x/zfs-job.sh "pve20 hourly backup (sync-test-all)" -- /x/snapget.sh -m "automated_hourly_" "%s" ""' % (
    mine[0]["schedule"], ",".join(x["other_end"] for x in mine))
for x in mine:
    x["cron_lines"] = [line]
json.dump(j, open(sys.argv[2], "w", encoding="utf-8"))
json.dump({"window_days": 7,
           "jobs": [{"label": "hourly backup (sync-test-all)", "runs": 2, "failures": 1, "avg_s": 6, "max_s": 6,
                     "total_s": 12, "last_s": 6, "last_rc": 1, "last_at": "2026-09-08 13:48"}],
           "events": [{"label": "hourly backup (sync-test-all)", "discard_at": "", "discard": "",
                       "error_at": "2026-09-08 13:48", "error": "cannot receive incremental stream: dataset is busy"}],
           "datasets": [], "volume": []}, open(sys.argv[3], "w", encoding="utf-8"))
PYEOF
sj_dump=""; sj_ok=0
for sjk in "" down down,down; do
    SJ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GSJ" --monitors "$GM" --stats "$GSS" --screen relacje --width 260 --height 60 --keys "$sjk" 2>&1)"
    has "$SJ" 'Przyczyna' || continue
    sj_dump="$SJ"
    pl="$(printf '%s\n' "$SJ" | grep 'Przyczyna')"
    if hasE "$SJ" 'Ostatni bieg +BŁĄD +2026-09-08 13:48 +rc=1 ' && ! hasE "$SJ" 'rc=1 +\(\+' \
       && printf '%s' "$pl" | grep -q 'lab/a' && printf '%s' "$pl" | grep -q 'lab/b' \
       && has "$SJ" 'dataset is busy'; then sj_ok=1; fi
    break
done
if [ "$sj_ok" -eq 1 ]; then
    ok "relacje: jedna linia crona dla kilku datasetow -- blad liczony raz, bez '(+N)', Przyczyna nie zrzuca go na pierwszy dataset"
else
    bad "relacje: wspolna linia crona" "$(printf '%s\n' "$sj_dump" | grep -E 'Ostatni bieg|Przyczyna' | head -4)"
fi
rm -f "$GSJ" "$GSS"
# REV-20261027-177: the dataset the error names is matched as a WHOLE name -- 'pool/vm-10'
# is not named by 'pool/vm-100', 'data' not by 'metadata'. The ACTUAL rel_panel_pairs, one
# shared cron label, two members; the reason line for each error text.
EXN="$("$PY" - "$TUI" <<'PYEOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.job_cron_label = lambda j: "shared"
class D:
    stats = {"window_days": 7}
    def failed(self, _): return False
def reason(scopes, err):
    m.job_run_issue = lambda data, j: ((1, "2026-10-27 13:00", err), None)
    row = {"kind": "relation", "name": "r", "rel": {"name": "r", "state": "active", "mode": "backup", "profile": "default"},
           "monitors": [], "vword": "aktualne", "verdict": "OK", "reasons": [], "last": None, "next_epoch": 0,
           "next": "-", "stats": {}, "gb": "-", "jobs": [{"section_kind": "dataset", "scope": x} for x in scopes]}
    out = {}
    for k, v in m.rel_panel_pairs(row, D(), 0, m.Chars(False)):
        out[k.strip()] = v
    return out.get("Przyczyna", "?") + " || " + out.get("Ostatni bieg", "?")
for name, sc, err in [
    ("prefix", ["pool/vm-10", "pool/vm-100"], "cannot receive pool/vm-100: dataset is busy"),
    ("short", ["data", "metadata"], "cannot receive metadata: dataset is busy"),
    ("none", ["pool/a", "pool/b"], "cannot receive incremental stream: dataset is busy"),
    ("both", ["pool/a", "pool/b"], "pool/a and pool/b: out of space."),
    ("target", ["hdd/vm-disks/subvol-103-disk-0", "rpool/ROOT/pve-1"], "Hint: 'hdd/backups/pve2/rpool/ROOT/pve-1' is MOUNTED"),
    ("remote", ["pool/vm-10", "pool/vm-100"], "zfsbackup@pve1:pool/vm-100@s1: refused"),
    ("child", ["pool/vm-10", "pool/vm-100"], "pool/vm-10/sub: busy"),
    # round 2: ':' is legal INSIDE a dataset name (lib-scope.sh pc_is_dataset)
    ("colon", ["pool/foo", "pool/other"], "cannot receive pool/foo:bar: dataset is busy"),
    ("colonpath", ["pool/bar", "pool/other"], "busy: pool/foo:pool/bar"),
    ("hostcolon", ["pool/foo", "pool/other"], "pve1:pool/foo: dataset is busy"),
    # round 3: a pool name may hold ':' before the first '/' ('x:pool/foo'); only
    # account@host: is a transport prefix ('@' is never part of a dataset name)
    ("xpoolmember", ["x:pool/foo", "pool/other"], "cannot receive x:pool/foo: dataset is busy"),
    ("xpooltext", ["pool/foo", "pool/other"], "cannot receive x:pool/foo: dataset is busy"),
    ("acctremote", ["zfsbackup@pve1:pool/foo", "pool/other"], "zfsbackup@pve1:pool/foo@s1: refused"),
    ("member", ["zfsbackup@pve1:pool/foo:bar", "pool/foo"], "cannot receive pool/foo:bar: dataset is busy")]:
    print("%s=%s" % (name, reason(sc, err)))
PYEOF
)"
exn() { printf '%s\n' "$EXN" | sed -n "s/^$1=//p"; }
if [ "$(exn prefix | cut -d: -f1)" = "pool/vm-100" ] && [ "$(exn short | cut -d: -f1)" = "metadata" ] \
   && [ "$(exn none | cut -d: -f1)" = "pool/a, pool/b" ] && [ "$(exn both | cut -d: -f1)" = "pool/a, pool/b" ] \
   && [ "$(exn target | cut -d: -f1)" = "rpool/ROOT/pve-1" ] && [ "$(exn remote | cut -d: -f1)" = "pool/vm-100" ] \
   && [ "$(exn child | cut -d: -f1)" = "pool/vm-10, pool/vm-100" ] && ! printf '%s' "$EXN" | grep -q '(+'    && [ "$(exn colon | sed 's/: cannot.*//')" = "pool/foo, pool/other" ] && [ "$(exn colonpath | sed 's/: busy.*//')" = "pool/bar, pool/other" ]    && [ "$(exn hostcolon | sed 's/: pve1.*//')" = "pool/foo, pool/other" ] && [ "$(exn xpoolmember | sed 's/: cannot.*//')" = "x:pool/foo" ] && [ "$(exn xpooltext | sed 's/: cannot.*//')" = "pool/foo, pool/other" ] && [ "$(exn acctremote | sed 's/: zfsbackup.*//')" = "pool/foo" ] && [ "$(exn member | sed 's/: cannot.*//')" = "pool/foo:bar" ]; then
    ok "relacje REV-177: blad przypisany datasetowi tylko przy calej nazwie (vm-10/vm-100, data/metadata, cel pod baza, host:ds; dwukropek W nazwie nie jest granica: pool/foo:bar, x:pool/foo; transport tylko konto@host:); nic albo dwa -> caly zakres; wspolna linia liczona raz"
else
    bad "relacje REV-177: przypisanie bledu" "$EXN"
fi
rm -f "$GEJ" "$GES"
# Wlasciciel 2026-10-08: "zmien synchro na lustro w GUI" -- dane ida w jedna
# strone, od backupu rozni sie tylko retencja. Panel F3 podaje typ relacji.
if has "$GR" 'lustro' && ! has "$GR" 'synchro'; then
    ok "relacje: relacja trybu sync nazywa sie na ekranie 'lustro', nie 'synchro'"
else
    bad "relacje: nazwa lustro na F3" "$GR"
fi

# ZRODLO I CEL W PANELU, W CALOSCI. Wlasciciel, 2026-09-11: "Zmieniamy nazwe
# Zakres na Cel i dodajemy tez Zrodlo". Dla pobrania zrodlo jest zdalne, cel
# to ladowisko tutaj; kierunek mowi, ktore jest ktorym.
if has "$Z" 'pve9:hdd/lab/vm-101' && has "$Z" 'hdd/backups/192.168.28.99/hdd/lab/vm-101' && hasE "$Z" 'Źródło +pve9:' && hasE "$Z" 'Cel +pve10:hdd/backups'; then
    ok "zadania: panel pobrania -- ZRODLO zdalne i CEL lokalny w osobnych wierszach, pelne sciezki"
else
    bad "zadania: zrodlo/cel w panelu" "$Z"
fi
ZP="$(screen zadania "$(zkeys "^║ $KD +lab-vm101 +lokalny prune " $ALL)" --width 200 --height 60)"
# Tylko PRAWY PANEL wiersza (po ramce listy): dolna zakladka 'Źródło → cel' ma swoj naglowek
# 'Źródło', ktory nie jest polem panelu.
ZPP="$(printf '%s\n' "$ZP" | sed -n 's/^.*║│//p')"
if hasE "$ZPP" 'Cel +pve10:hdd/backups/192.168.28.99/hdd/lab/vm-101' && ! hasE "$ZPP" 'Źródło +'; then
    ok "zadania: porzadki maja tylko CEL (to, co przycinaja)"
else
    bad "zadania: porzadki zrodlo/cel" "$ZPP"
fi
ZH2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --keys down,down 2>&1)"
# down,down: widok domyslny grupuje wiersze relacji -- oba "(bez rel.)" sa pierwsze
ZH2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --keys down,down --width 160 2>&1)"
if has "$ZH2" 'hdd/vm-disks/subvol-100-disk-0' && has "$ZH2" 'pve9:hdd/backups' && hasE "$ZH2" 'Źródło +hostA:hdd/vm-disks'; then
    ok "zadania: dla WYSYLKI zrodlo jest tutaj, a cel u peera"
else
    bad "zadania: wysylka zrodlo/cel" "$ZH2"
fi
# F2 Przebiegi: kazdy bieg to wiersz 'dd.mm HH:MM  relacja  zadanie ...'; wiersze wysylki,
# pobrania i kopii sa na liscie (szeroko, 160: przy 120 kolumna Co by odpadla), nie na jednym numerze.
ZH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 160 --height 100 2>&1)"
if hasE "$ZH" "^║ $KD +pve9 +wysyłka " && hasE "$ZH" "^║ $KD +pve1 +pobranie " && hasE "$ZH" "^║ $KD +\(bez rel\.\) +kopia "; then
    ok "zadania: wysylka, pobranie i kopia na hoscie w liscie; zadanie bez etykiety mowi '(bez rel.)' (kierunek w panelu, U21)"
else
    bad "zadania: trzy kierunki na hostA" "$ZH"
fi
ZE="$(screen zadania enter --height 80)"
if has "$ZE" '╔═ Zadanie: lab-vm101 ' && has "$ZE" 'pve9:hdd/lab/vm-101' && has "$ZE" 'hdd/backups/192.168.28.99/hdd/lab/vm-101' \
        && hasE "$ZE" 'Trzyma +-' && has "$ZE" '── CONFIG ' && has "$ZE" '── CRON ' && has "$ZE" 'snapget.sh' \
        && has "$ZE" '[dataset:hdd/backups/192.168.28.99/hdd/lab/vm-101]' && has "$ZE" '[template:profile__default__standard_hourly]' \
        && ! has "$ZE" '[template:profile__default__keep_monthly]'; then
    ok "zadania: Enter = szczegoly + CONFIG (TYLKO sekcja i szablon tego zadania) + CRON z prawdziwa linia (R4-6)"
else
    bad "zadania: Enter" "$ZE"
fi
# F5 ZNIESIONY (uwaga 2): to, co dawal ekran Monitor -- harmonogram straznika,
# progi -- wchodzi teraz do panelu F2 (rel_detail_pairs), dopasowane TA SAMA
# regula co werdykt (monitors_for_job); R3-3 laczy straznik+progi w JEDNA
# linie. Z fikstur pve10: lab-vm101 ma monitor "*/15 * * * *", warn 90m, crit 150m.
if hasE "$ZE" 'Strażnik +ostrzeżenie po 90m, alarm po 150m   sprawdza co 15 min'; then
    ok "zadania: panel F2 nazywa straznika (progi i harmonogram) w JEDNEJ linii -- to, co dawal usuniety F5"
else
    bad "zadania: straznik/progi w panelu F2" "$ZE"
fi
# STRAZNIK BEZ ZADANIA (uwaga 3): monitor, ktory NIE dopasowal sie do zadnego
# zadania na F2, nie moze zniknac -- watchdog pilnujacy czegos, czego juz nie
# ma w cronie, jest samodzielnym wierszem "straznik bez zadania".
ZG="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/monitor-orphan.json" --screen zadania --width 200 2>&1)"
# Wiersz tylko-do-czytania z gory listy: Kiedy '-' (nie cron), Wynik = werdykt strażnika.
if hasE "$ZG" '^║ - +ghost +strażnik bez zadania +aktualne'; then
    ok "zadania: monitor bez dopasowanego zadania jest WIERSZEM 'straznik bez zadania' (F5 zniesiony, uwaga 3)"
else
    bad "zadania: straznik bez zadania" "$ZG"
fi
ZGE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/monitor-orphan.json" --screen zadania --keys enter 2>&1)"
if hasE "$ZGE" 'Relacja +ghost' && has "$ZGE" 'hdd/nowhere/ghost'; then
    ok "zadania: Enter na straznikiu bez zadania otwiera monitor_detail_pairs (to, co dawal F5)"
else
    bad "zadania: panel straznika bez zadania" "$ZGE"
fi

# ============================================================================
# EKRAN F3: RELACJE -- AKCJE. Komenda bash NAJPIERW, potem 't', potem wyjscie.
# ============================================================================
# Wlasciciel, 2026-09-09: "przypominam o podgladzie komendy bash". Czasowniki
# nie sa uruchamiane: --exec-log zapisuje DOKLADNA linie, ktora poszlaby do
# powloki, i to ona jest asercja. Atrapa ma ten sam przebieg sterowania, co
# prawdziwy bieg (okno wyjscia, komunikat) -- rozni sie tylko brakiem procesu.
XL="$(mktemp)"
act() {   # <keys> [extra] -> ekran; dziennik komend w $XL (wyzerowany)
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen relacje --keys "$1" "${@:2}" 2>&1
}
ZB="$(cd "$REPO" && pwd)/zfs-backup.sh"
A="$(act down,F8)"
if has "$A" '╔═ POTWIERDZENIE: Wstrzymaj relację lab-ct201 ═' && has "$A" 'Wykona się DOKŁADNIE to:' \
        && has "$A" 'pause-client'; then   # the shell line WRAPS on a long checkout path (CI: /home/runner/work/...), so the verb and the name may sit on different lines
    ok "akcje: F8 na relacji aktywnej pokazuje komende pause-client PRZED wykonaniem"
else
    bad "akcje: F7 podglad pauzy" "$A"
fi
if [ ! -s "$XL" ]; then
    ok "akcje: ...i sam podglad NICZEGO nie uruchamia"
else
    bad "akcje: podglad nie uruchamia" "$(cat "$XL")"
fi
# WYŁĄCZ (właściciel 2026-10-18): w oknie pauzy 'w' = wariant "wyłącz także na źródle",
# z wyjaśnieniem, co to znaczy i jak włączyć z powrotem; 't' wykonuje disable-client.
A="$(act down,F8)"
B="$(act down,F8,w --height 50)"
# U7 (właściciel 10-18): klawisz wariantu na RAMCE obok "t wykonaj", nie w treści okna.
if has "$A" 't wykonuje   w wyłącz na źródle   Tab do linii poleceń' && ! hasE "$A" '║ *[a-z] = ' && has "$B" 'POTWIERDZENIE: Wyłącz relację lab-ct201' \
   && has "$B" 'disable-client' && has "$B" 'zamek na źródle' && has "$B" 'F8 na tej relacji -> Włącz (enable-client).' && [ ! -s "$XL" ]; then
    ok "akcje: F8 -> 'w' (na ramce, nie w treści) pokazuje Wyłącz (disable-client) z wyjaśnieniem i drogą powrotu, niczego nie uruchamia"
else
    bad "akcje: F8 -> w (wyłącz)" "$A" "$B"
fi
A="$(act down,F8,w,t)"
if grep -q "disable-client lab-ct201 '--reason=wyłączona z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ]; then
    ok "akcje: ...'t' wykonuje disable-client NAZWA --reason=..."
else
    bad "akcje: F8 -> w -> t" "$(cat "$XL")"
fi
DISD="$(mktemp -d)"; "$PY" - "$P10/status-paused.json" "$DISD/status.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for r in d.get("relations", []):
    if r.get("paused_local"):
        r["disabled"] = True
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
DIS="--status $DISD/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor-paused.json --progress $P10/progress.json --replicas $P10/replicas.json"
: > "$XL"
SDW="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $DIS --exec-log "$XL" --screen relacje --keys down,down,down --width 160 2>&1)"
SDT="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $DIS --exec-log "$XL" --screen relacje --keys down,down,down,F8,t --width 160 2>&1)"
if has "$SDW" 'F8 Włącz' && has "$SDW" 'WYŁĄCZONA' && grep -q "enable-client lab-srv-b\$\|enable-client lab-srv-b'\?\$" "$XL"; then
    ok "akcje: relacja WYŁĄCZONA -- stan 'WYŁĄCZONA', pasek 'F8 Włącz', F8 + t = enable-client (nie resume, który zostawiłby zamek na źródle)"
else
    bad "akcje: F8 na wyłączonej" "$(printf '%s' "$SDW" | grep -E 'F8|WYŁĄ' | head -3)" "$(cat "$XL")"
fi
rm -rf "$DISD"
A="$(act down,F8,t)"
if grep -q "pause-client lab-ct201 '--reason=z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ] && has "$A" '╔═ WYJŚCIE: Wstrzymaj relację lab-ct201 ═' && has "$A" '[tryb testowy]'; then
    ok "akcje: 't' wykonuje DOKLADNIE pokazana komende (pause-client NAME --reason=...) i otwiera okno wyjscia"
else
    bad "akcje: t wykonuje" "$(cat "$XL")" "$A"
fi
A="$(act down,F8,esc)"
if [ ! -s "$XL" ] && has "$A" 'anulowano -- nic nie wykonano'; then
    ok "akcje: Esc w potwierdzeniu anuluje i mowi to; dziennik pusty"
else
    bad "akcje: Esc anuluje" "$(cat "$XL")" "$A"
fi
A="$(act down,F8,q)"
if [ ! -s "$XL" ] && has "$A" 'anulowano'; then
    ok "akcje: KAZDY klawisz poza 't' anuluje (tu: q) -- nie ma przypadkowego wykonania"
else
    bad "akcje: inny klawisz anuluje" "$(cat "$XL")" "$A"
fi
# pauza -> wznowienie: ta sama litera, przeciwny czasownik, decyduje REKORD
AP="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --exec-log "$XL" --screen relacje --keys down,down,down,F8,t 2>&1)"
if grep -q "resume-client lab-srv-b$" "$XL" && has "$AP" 'WYJŚCIE: Wznów relację lab-srv-b'; then
    ok "akcje: F8 na relacji WSTRZYMANEJ wola resume-client (decyduje paused_local z rekordu)"
else
    bad "akcje: F7 = resume na pauzie" "$(cat "$XL")" "$AP"
fi
# R4-1 (wlasciciel 2026-09-24): F4 na F3 to GLOWNE OKNO (dzis Kopie), nie pauza --
# klawisze F1-F6 sa zawsze glownymi oknami; pauza jest na F8.
A="$(act F4)"
if has "$A" '╔═ Kopie na pve10' && ! has "$A" 'POTWIERDZENIE' && [ ! -s "$XL" ]; then
    ok "akcje: F4 na ekranie Relacje przelacza na Kopie (R4-1), nie wstrzymuje relacji"
else
    bad "akcje: F4 na F3" "$A"
fi
# F7 = URUCHOM TERAZ (wlasciciel 2026-10-17, jednolicie z F2/F6): bez potwierdzenia,
# run-relation NAZWA, okno wyjscia.
A="$(act down,F7)"
if grep -q "run-relation lab-ct201$" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ] && ! has "$A" 'POTWIERDZENIE' && has "$A" 'WYJŚCIE: Relacja lab-ct201 -- kopia teraz'; then
    ok "akcje: F7 na relacji = Uruchom teraz -- run-relation NAZWA od razu, bez potwierdzenia, okno wyjscia"
else
    bad "akcje: F7 Uruchom teraz" "$(cat "$XL")" "$A"
fi
# F9 = okienko Eksport/Import; Esc wraca, nic nie wykonane.
A="$(act down,F9)"
if has "$A" 'Relacja lab-ct201 -- eksport / import' && has "$A" '> Eksport relacji lab-ct201 do pliku' && has "$A" 'Import relacji z pliku' && [ ! -s "$XL" ]; then
    ok "akcje: F9 na relacji = okienko wyboru Eksport / Import (kursor na Eksporcie), nic nie wykonane"
else
    bad "akcje: F9 okienko" "$A"
fi
A="$(act down,F9,esc)"
if [ ! -s "$XL" ] && has "$A" 'anulowano -- nic nie wykonano' && ! has "$A" 'eksport / import'; then
    ok "akcje: Esc w okienku F9 wraca i mowi 'anulowano'"
else
    bad "akcje: F9 Esc" "$A"
fi
# EKSPORT (R4-8, R4-10): domyslnie w katalogu relacji (/etc/zfs-snapshot-all/relations,
# w testach ZFS_TUI_RELATIONS_DIR), Enter ZAPISUJE -- bez drugiego 't'.
RD="$(mktemp -d)"; RDP="$RD"; command -v cygpath >/dev/null 2>&1 && RDP="$(cygpath -m "$RD")"
export ZFS_TUI_RELATIONS_DIR="$RDP"
A="$(act down,F9,enter)"
if has "$A" '╔═ Eksport relacji lab-ct201 ═' && has "$A" "$RDP" && has "$A" 'lab-ct201.export.json_' && has "$A" 'nadpisany'    && has "$A" 'Enter zapisuje' && ! has "$A" 'Enter dalej'; then
    ok "akcje: F8 podpowiada sciezke w katalogu relacji (<dir>/<relacja>.export.json) i mowi, ze istniejacy plik bedzie nadpisany"
else
    bad "akcje: F8 podpowiedz" "$A"
fi
A="$(act down,F9,enter,enter)"
if grep -q "export-relation lab-ct201 --json > .*lab-ct201.export.json'\?$" "$XL" && ! has "$A" 'POTWIERDZENIE' && has "$A" 'WYJŚCIE: Eksport relacji lab-ct201'; then
    ok "akcje: Enter w polu sciezki od razu wykonuje eksport DO tego pliku -- bez potwierdzenia 't' (R4-8)"
else
    bad "akcje: F8 Enter zapisuje" "$(cat "$XL")" "$A"
fi
A="$(act down,F9,enter,bs,bs,bs,bs,text:yaml,enter)"
if grep -q "export-relation lab-ct201 --json > .*lab-ct201.export.yaml'\?$" "$XL"; then
    ok "akcje: ...Backspace i wpisany tekst zmieniaja sciezke, a eksport idzie do NIEJ"
else
    bad "akcje: F8 edycja sciezki" "$(cat "$XL")" "$A"
fi
ZFS_TUI_RELATIONS_DIR="$RDP/nowy" act down,F9,enter,enter >/dev/null
if [ -d "$RD/nowy" ] && grep -q "nowy.lab-ct201.export.json" "$XL"; then
    ok "akcje: eksport do katalogu, ktorego nie ma -- katalog jest tworzony (pierwszy eksport na hoscie)"
else
    bad "akcje: F8 tworzy katalog" "$(ls -la "$RD")" "$(cat "$XL")"
fi
# IMPORT (R4-9): LISTA plikow katalogu relacji, nie wpisywanie sciezki.
# W katalogu: plik eksportu, plik JSON, ktory NIE jest eksportem, i podkatalog.
printf '{"schema":"zfs-backup/relation-export/1","name":"pve9-synchro"}' > "$RD/pve9-synchro.export.json"
printf '{"x":1}' > "$RD/cos-innego.json"
mkdir -p "$RD/archiwum"
A="$(act down,F9,down,enter)"
if has "$A" '╔═ Import relacji z pliku' && has "$A" '> pve9-synchro.export.json' && has "$A" 'relacja pve9-synchro' \
   && has "$A" 'archiwum/' && has "$A" '..' && has "$A" '[ wpisz ścieżkę ręcznie ]' && ! has "$A" 'cos-innego.json'; then
    ok "akcje: F9 = lista plikow katalogu relacji: '..', katalogi, TYLKO pliki eksportu (z nazwa relacji), kursor na eksporcie, na koncu 'wpisz recznie' (R4-9)"
else
    bad "akcje: F9 lista plikow" "$A"
fi
A="$(act down,F9,down,enter,enter)"
if has "$A" 'POTWIERDZENIE: Import relacji z pve9-synchro.export.json' && has "$A" '[atrapa] podgląd:'; then
    ok "akcje: Enter na pliku z listy = werdykt/plan importu tego pliku"
else
    bad "akcje: F9 Enter na pliku" "$A"
fi
A="$(act down,F9,down,enter,up,enter)"
if has "$A" '╔═ Import relacji z pliku' && has "$A" '  ..' && has "$A" '> [ wpisz' && ! has "$A" 'pve9-synchro.export.json'; then
    ok "akcje: Enter na katalogu wchodzi do niego (archiwum: pusty, sam '..' i 'wpisz recznie')"
else
    bad "akcje: F9 wejscie do katalogu" "$A"
fi
rm -rf "$RD/archiwum" "$RD/cos-innego.json"
# import przez 'wpisz sciezke recznie': podglad (bez --yes) w potwierdzeniu, potem --yes
IMPF="$(mktemp)"
printf '{"schema":"zfs-backup/relation-export/1","name":"pve9-synchro"}' > "$IMPF"
IMPP="$IMPF"; command -v cygpath >/dev/null 2>&1 && IMPP="$(cygpath -m "$IMPF")"   # Git Bash: Python spod Windows nie zna /tmp
CLR="$(printf 'bs,%.0s' $(seq 60))"; CLR="${CLR%,}"   # zdejmuje podpowiedz katalogu domowego -- sciezka wpisana ZA nia bylaby /root//tmp/...; 60, bo Git Bash robi z HOME=/root dluga sciezke pod Program Files
A="$(HOME=/root act "down,F9,down,enter,end,enter,$CLR,text:$IMPP,enter")"
if has "$A" "POTWIERDZENIE: Import relacji z $(basename "$IMPF")" && has "$A" 'import-relation' && hasE "$A" "$(basename "$IMPF")'? --yes" && has "$A" '[atrapa] podgląd:'; then
    ok "akcje: F9 -> 'wpisz recznie' -> plik: PODGLAD czasownika (bez --yes) i komenda z --yes do potwierdzenia"
else
    bad "akcje: F9" "$A"
fi
A="$(HOME=/root act "down,F9,down,enter,end,enter,$CLR,text:$IMPP,enter,t")"
if grep -q "import-relation .*$(basename "$IMPF")'\? --yes$" "$XL"; then
    ok "akcje: ...i 't' wola import-relation PLIK --yes"
else
    bad "akcje: F9 t" "$(cat "$XL")"
fi
# F9 z nieistniejaca sciezka: podpowiedz "/root/" + dopisana wzgledna sciezka
# skladala sie w /root/tmp/f8.json, ktorej nie ma -- czasownik odmawial "cannot
# read", operator dowiadywal sie o tym po nazwie relacji (pve10, 2026-09-23).
A="$(HOME=/root act "down,F9,down,enter,end,enter,text:tmp/nie-ma-takiego.json,enter")"
if has "$A" 'Import relacji z pliku' && has "$A" 'nie ma takiego pliku' && [ ! -s "$XL" ]; then
    ok "akcje: F9 z nieistniejaca sciezka zostaje w polu pliku, mowi 'nie ma takiego pliku' i nic nie uruchamia (pve10: /root/ + tmp/f8.json)"
else
    bad "akcje: F9 nieistniejaca sciezka" "$A" "$(cat "$XL")"
fi
# F9 nie ma juz kroku z nazwa (2026-09-23): werdykt daje czasownik bez --yes
# (juz jest i identyczna / rozni sie / plan), --name zostaje w CLI. Routing
# werdyktu na PRAWDZIWYM czasowniku jest dowiedziony na pve10 -- w trybie
# atrapy czasownik sie nie wykonuje, wiec tu jest tylko brak kroku z nazwa.
A="$(HOME=/root act "down,F9,down,enter,end,enter,$CLR,text:$IMPP,enter")"
if ! has "$A" 'Nazwa relacji' && has "$A" 'POTWIERDZENIE: Import relacji'; then
    ok "akcje: F9 po pliku idzie prosto do werdyktu/planu -- bez pola nazwy"
else
    bad "akcje: F9 bez kroku z nazwa" "$A"
fi
rm -f "$IMPF"; rm -rf "$RD"; unset ZFS_TUI_RELATIONS_DIR
# F9/Ins na PUSTYM kolektorze (zero relacji, zero zadan): milczaly, bo szukaly
# najpierw zaznaczonej relacji, ktorej na pustym ekranie nie ma (pve11,
# 2026-09-23). Fikstura empty.json/empty-mon.json (linia 297) to jedyny host
# bez zadnego rekordu -- brak --status daje 0 relacji.
act_empty() {   # <keys> -> ekran; dziennik komend w $XL (wyzerowany)
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/empty-mon.json" --exec-log "$XL" --screen relacje --keys "$1" 2>&1
}
E="$(act_empty "")"
if has "$E" 'Ins nowa relacja' && ! has "$E" 'F9 import z pliku' && hasE "$E" '9Plik|F9 Eksport/Import'; then
    ok "akcje: pusty kolektor -- ramka podpowiada Ins nowa relacja, F9 Import jest na pasku (pve11 2026-09-23; uwaga 4)"
else
    bad "akcje: pusty kolektor stopka" "$E"
fi
E="$(act_empty F9)"
if has "$E" 'Import relacji z pliku'; then
    ok "akcje: pusty kolektor -- F9 otwiera import (wczesniej milczal: brak zaznaczonej relacji)"
else
    bad "akcje: pusty kolektor F9" "$E"
fi
# odmowy PRZED czymkolwiek: rekord usuniety, wiersz bez rekordu, inny ekran
A="$(act end,F7)"; act end,F7,t >/dev/null
if [ ! -s "$XL" ] && has "$A" "relacja '192.168.28.99' jest już usunięta"; then
    ok "akcje: na rekordzie 'removed' PAUZA odmawia, mowi dlaczego, i nic nie idzie do powloki (Del tam dziala -- zwalnia nazwe)"
else
    bad "akcje: removed odmawia" "$(cat "$XL")" "$A"
fi
AH="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F7 2>&1)"
"$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F7,t >/dev/null 2>&1
if [ ! -s "$XL" ] && has "$AH" 'to nie jest relacja (zadanie bez rekordu)'; then
    ok "akcje: na zadaniu BEZ rekordu (ksztalt produkcji) akcja odmawia -- nie ma czego pauzowac czasownikiem"
else
    bad "akcje: bez rekordu odmawia" "$(cat "$XL")" "$AH"
fi
A="$(act down,ins)"
if grep -Eq "zfs-backup.sh'? new-relation\$" "$XL" && ! has "$A" 'krok 1/8'; then
    ok "akcje: Ins na F3 oddaje terminal czasownikowi new-relation (kreator whiptail), NIE otwiera starego kreatora w curses"
else
    bad "akcje: Ins -> new-relation" "$(cat "$XL")" "$A"
fi
A="$(act down,del)"
if grep -Eq "zfs-backup.sh'? delete-relation lab-ct201 --ask\$" "$XL"; then
    ok "akcje: Del na F3 oddaje terminal dialogowi CALEGO usuwania (delete-relation NAZWA --ask), nie samemu remove-client"
else
    bad "akcje: Del -> delete-relation --ask" "$(cat "$XL")"
fi
# F4 KOPIE (U82; dawny F11 Odzysk danych), DWA PANELE jak mc: lewy = datasety kopii w grupach
# "▸ relacja NAZWA" i "▸ replika NAZWA" (+ wiersz 'inny dysk'), prawy = `zfs list -t snapshot DATASET`
# (NAME USED REFER CREATION), dol = Szczegoly. Enter/F7 na MIGAWCE = PRZEGLADAJ (browse NAZWA --ask
# --snapshot=PELNA_NAZWA), F9 = PRZYWROC (restore NAZWA --ask --dataset=DS [--snapshot=KROTKA]);
# na 'inny dysk' stare okna wyboru (browse --any --ask, restore --from-copy --ask). 'p' w oknie
# relacji niczego nie robi. Offline nie uruchamia czasownikow: datasety i migawki ida z fikstur
# --zfs-tree / --zfs-snapshots. Ekran osiagamy KLAWISZEM F4 z F3 (kursor na pierwszej relacji).
# Godziny w CREATION zaleza od TZ biegacza -- asercje nie nazywaja godziny, tylko migawke i slowo.
od() {   # <keys po F4> -> ekran F4 Kopie; dziennik w $XL
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --zfs-tree "$P10/zfs-tree.json" --zfs-snapshots "$P10/zfs-snapshots.json" --exec-log "$XL" --screen relacje --keys "F4${1:+,$1}" --width 150 --height 30 "${@:2}" 2>&1
}
OZT="--zfs-tree $P10/zfs-tree.json --zfs-snapshots $P10/zfs-snapshots.json"
VM101="hdd/backups/192.168.28.99/hdd/lab/vm-101"
CT201="hdd/backups/192.168.28.99/hdd/lab/ct-201"
A="$(od "")"
# Od 2026-10-29 (wlasciciel: „Zrob go taki sam jak w jobs”) F4 w ukladzie F2: tabela kopii
# (Relacja, Kopia, Migawek, Najnowsza), fakty z prawej, migawki w dolnej zakladce [Migawki].
if has "$A" '╔═ Kopie na pve10' && ! has "$A" 'Odzysk danych' && hasE "$A" 'Relacja +Kopia +Migawek +Najnowsza' \
   && hasE "$A" "^║ duplikat +$VM101 +3 " && hasE "$A" "^║ lab-ct201 +$CT201 +3 " \
   && has "$A" "$VM101: [Migawki]" && has "$A" '@automated_hourly_2026-09-09_11-20-01' \
   && has "$A" 'NAME' && has "$A" 'USED' && has "$A" 'REFER' && has "$A" 'CREATION' \
   && has "$A" 'Enter/Tab do migawek' && ! has "$A" '▸ relacja'; then
    ok "kopie: F4 w ukladzie F2 -- tabela Relacja/Kopia/Migawek/Najnowsza ('duplikat  VM101  3'), dolna zakladka '[Migawki]' z kolumnami NAME USED REFER CREATION i wierszami '@migawka'"
else
    bad "kopie: ekran F4 Kopie" "$A"
fi
A="$(od "" --width 200 --height 50)"
if hasE "$A" 'sejf-a .*nośnik niepodłączony -- podłącz go, potem Ctrl-R' && hasE "$A" 'sejf-b .*nośnik niepodłączony -- podłącz go, potem Ctrl-R' \
   && has "$A" 'inny dysk -- pula spoza relacji i replik' \
   && hasE "$A" "Dataset +$VM101" && hasE "$A" 'Relacja +duplikat +backup' && hasE "$A" 'Migawek +3' && ! hasE "$A" 'Migawka +@'; then
    ok "kopie: repliki z nosnikiem niepodlaczonym -- wiersz z uwaga 'podłącz go, potem Ctrl-R'; ostatni wiersz 'inny dysk'; panel: Dataset/Relacja/Migawek, bez Migawki gdy fokus na liscie"
else
    bad "kopie: repliki, 'inny dysk', Szczegoly" "$A"
fi
A="$(od "" --width 140 | tail -1)"
if has "$A" 'F4 Kopie' && has "$A" 'F9 Przywróć' && has "$A" 'F12 Wyjście' && ! has "$A" 'F11' && ! has "$A" 'Odzysk' && ! has "$A" 'Historia' && has "$A" 'F7 Przeglądaj'; then
    ok "odzysk: pasek F4 -- 'F4 Kopie' i akcje 'F7 Przeglądaj' (U85) i 'F9 Przywróć', bez F11, Odzysku i Historii"
else
    bad "odzysk: pasek F4" "$A"
fi
A="$(od enter)"
if [ ! -s "$XL" ] && has "$A" 'Enter przeglądaj   F9 przywróć   Esc wraca' && ! has "$A" 'Enter/Tab do migawek' && hasE "$A" 'Migawka +@automated_hourly_2026-09-09_11-20-01' && hasE "$A" 'Dataset +hdd/backups/192\.168\.28\.99/hdd/lab/vm-101'; then
    ok "kopie: Enter na DATASECIE tylko przenosi fokus do zakladki Migawki (nic nie uruchamia), kursor na najnowszej migawce; Szczegoly pokazuja Migawke"
else
    bad "kopie: Enter na datasecie" "$(cat "$XL")" "$(printf '%s' "$A" | tail -4)"
fi
A="$(od tab,down,enter)"
if grep -Eq "zfs-backup.sh'? browse duplikat --ask --snapshot=$VM101@automated_hourly_2026-09-09_10-20-01\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: Tab, down, Enter na MIGAWCE -- browse duplikat --ask --snapshot=PELNA_NAZWA (druga migawka, nie najnowsza)"
else
    bad "kopie: Enter na migawce" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od tab,down,F7)"
if grep -Eq "zfs-backup.sh'? browse duplikat --ask --snapshot=$VM101@automated_hourly_2026-09-09_10-20-01\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: F7 na migawce = Przeglądaj, jak Enter (U85)"
else
    bad "kopie: F7 na migawce" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od enter,down,F9)"
if grep -Eq "zfs-backup.sh'? restore duplikat --ask --dataset=$VM101 --snapshot=automated_hourly_2026-09-09_10-20-01\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: F9 na migawce -- restore duplikat --ask --dataset=DS --snapshot=KROTKA_NAZWA (bez czesci przed @)"
else
    bad "kopie: F9 na migawce" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od down,F9)"
if grep -Eq "zfs-backup.sh'? restore lab-ct201 --ask --dataset=$CT201\$" "$XL" && ! grep -q -- '--snapshot' "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: F9 na DATASECIE (fokus na liscie) -- restore lab-ct201 --ask --dataset=DS, bez --snapshot="
else
    bad "kopie: F9 na datasecie" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od end,enter)"
if grep -Eq "zfs-backup.sh'? browse --any --ask\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: Enter na 'inny dysk' -- browse --any --ask (dowolny dataset tego hosta)"
else
    bad "kopie: Enter na inny dysk" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od end,F9)"
if grep -Eq "zfs-backup.sh'? restore --from-copy --ask\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "kopie: F9 na 'inny dysk' oddaje terminal oknu 'Przywróć z dysku' (restore --from-copy --ask)"
else
    bad "kopie: F9 na inny dysk" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od end)"
if has "$A" 'inny dysk -- pula spoza relacji i replik' && has "$A" 'zpool import'; then
    ok "kopie: kursor na 'inny dysk' -- prawy panel i Szczegoly mowia o puli spoza relacji (zpool import)"
else
    bad "kopie: panel 'inny dysk'" "$A"
fi
# GRUPY jak F2 (F8, wlasciciel 2026-10-29 „tak jak F2 -- wszystkie mozliwosci”): naglowek
# relacji z rodzajem, pod nim jej kopie z wcieciem; pasek mowi „F8 Jedna lista”.
A="$(od F8)"
if has "$A" 'Kopie na pve10, po relacjach' && hasE "$A" '▸ duplikat +backup' && hasE "$A" "│ $VM101 +3 " && has "$A" 'F8 Jedna lista'; then
    ok "kopie: F8 grupuje po relacji jak F9 na F2 -- naglowek '▸ duplikat  backup', pod nim '│ VM101  3', pasek 'F8 Jedna lista'"
else
    bad "kopie: grupowanie F8" "$(printf '%s\n' "$A" | head -12)"
fi
# Wybor w prawym panelu: zaznaczony wiersz lewego panelu dostaje znacznik "▸ ct-201", a dol
# podaje migawke i slowo Czas (godzine pomijamy: zalezy od TZ).
A="$(od down,enter,down)"
if has "$A" "$CT201: [Migawki]" && hasE "$A" "lab-ct201 +$CT201 " && hasE "$A" 'Migawka +@automated_hourly_2026-09-09_10-20-01' && hasE "$A" "Dataset +$CT201" && hasE "$A" 'Czas +20' && has "$A" 'Esc wraca'; then
    ok "kopie: down, Enter, down -- zakladka Migawki ct-201 z fokusem, panel: Migawka (druga) i Czas"
else
    bad "kopie: fokus w prawym panelu" "$(printf '%s\n' "$A" | grep -E 'Migawki\]|ct-201|Migawka|Czas|Esc wraca')"
fi
# Dataset BEZ migawek (srv-b): prawy panel mowi o tym wprost, Enter zostawia fokus na liscie.
# srv-b szukany po tytule prawego panelu (kolejnosc grup zalezy od fikstur), potem Enter.
k=""; for _i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do A="$(od "${k}enter")"; hasE "$A" '/srv-b: \[Migawki\]' && break; k="${k}down,"; done
if hasE "$A" '/srv-b: \[Migawki\]' && has "$A" 'brak migawek' && has "$A" 'Enter/Tab do migawek' && ! has "$A" 'Esc wraca' && [ ! -s "$XL" ]; then
    ok "kopie: dataset bez migawek (srv-b) -- 'brak migawek', Enter nie przenosi fokusu do pustego prawego panelu i niczego nie uruchamia"
else
    bad "kopie: dataset bez migawek" "$(printf '%s\n' "$A" | grep -E 'Migawki\]|migawek|Esc wraca')" "log: $(cat "$XL")"
fi
# F4 Z F3: kursor Kopii staje na PIERWSZYM datasecie relacji z F3, fokus na LISCIE (Enter tylko
# przenosi fokus, niczego nie uruchamia); fokus w zakladce Datasety (Tab) = kursor na lokalnym
# celu TEJ pary. Brak kontekstu biegu: bez wyboru migawki (to robi tylko F4 z Przebiegow).
A="$(od enter)"
if [ ! -s "$XL" ] && has "$A" "$VM101: [Migawki]" && has "$A" 'Esc wraca'; then
    ok "kopie: F4 z wiersza relacji na F3 (fokus na liscie) -- kursor na pierwszym datasecie relacji, Enter tylko przenosi fokus (bez browse)"
else
    bad "kopie: F4 z F3, fokus na liscie" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
: > "$XL"
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL $OZT --exec-log "$XL" --screen relacje --keys tab,F4 --width 200 2>&1)"
if has "$A" '╔═ Kopie na pve10' && has "$A" "$VM101: [Migawki]" && has "$A" 'Enter/Tab do migawek' && ! hasE "$A" 'Migawka +@' && [ ! -s "$XL" ]; then
    ok "kopie: F4 z zakladki Datasety na F3 -- kursor na celu tej pary (vm-101), fokus na liscie, bez --at=/--snapshot= (nic nie uruchomiono)"
else
    bad "kopie: F4 z F3, fokus w Datasety" "$(printf '%s\n' "$A" | grep -E 'Kopie na|Migawki\]|Migawka|Enter/Tab')" "log: $(cat "$XL")"
fi
# F4 na relacji BEZ kopii (rekord usuniety): Kopie sie otwiera, ale bez kontekstu, z komunikatem.
# Z fikstura drzewa: bez niej KAZDA relacja wygladalaby na "bez kopii" (offline nie ma drzewa).
A="$(act end,F4 --width 130 $OZT)"
if has "$A" '╔═ Kopie na pve10' && has "$A" 'nie ma kopii na tym hoście -- nie ma czego przeglądać' && ! has "$A" 'Esc wraca' && [ ! -s "$XL" ]; then
    ok "kopie: F4 na relacji bez kopii (usunieta) -- Kopie bez kontekstu i komunikat 'nie ma kopii na tym hoście'"
else
    bad "kopie: F4 na relacji bez kopii" "$(printf '%s\n' "$A" | grep -E 'Kopie na|zfs list|kopii')" "log: $(cat "$XL")"
fi
if grep -q '^        browse)$' "$REPO/zfs-backup.sh" && grep -q 'tui/browse.sh' "$REPO/zfs-backup.sh" && bash -n "$REPO/tui/browse.sh" \
   && grep -q 'mount -t zfs -o ro' "$REPO/tui/browse.sh" && grep -q 'trap cleanup EXIT' "$REPO/tui/browse.sh"; then
    ok "odzysk: browse --ask prowadzi do tui/browse.sh; montaż -o ro, sprzątanie w trap EXIT"
else
    bad "odzysk: browse -> tui/browse.sh" "brak przekazania albo montażu ro"
fi
A="$(act down,enter,p)"
if [ ! -s "$XL" ] && ! has "$A" 'p przywróć'; then
    ok "odzysk: 'p' w oknie relacji niczego nie uruchamia i stopka o nim nie mówi (odzysk jest na F4 Kopie)"
else
    bad "odzysk: p w oknie relacji" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
: > "$XL"
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen nosniki --keys F9 2>&1)"
if [ ! -s "$XL" ] && has "$A" 'przywracanie z dysku jest teraz na F4 Kopie (F9)'; then
    ok "odzysk: F9 na F6 niczego nie uruchamia, mowi gdzie jest odzysk (F4 Kopie, F9)"
else
    bad "odzysk: F9 na F6" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen nosniki --width 80 2>&1 | grep 'Pomoc' | tail -1)"
if has "$A" '4Kopie' && has "$A" '12Wyj' && ! has "$A" '11' && ! has "$A" 'Odzysk' && ! has "$A" '9Przyw'; then
    ok "akcje: pasek F6 przy 80 kolumnach -- bez F9, z 4Kopie i 12Wyj(ście/dź), bez F11"
else
    bad "akcje: pasek F6 przy 80 kolumnach" "$A"
fi
if grep -q 'restore)' "$REPO/zfs-backup.sh" && grep -q 'tui/restore.sh' "$REPO/zfs-backup.sh"; then
    ok "akcje: zfs-backup.sh restore NAZWA --ask prowadzi do tui/restore.sh"
else
    bad "akcje: restore --ask -> tui/restore.sh" "brak przekazania w zfs-backup.sh"
fi
# ZMIANA RELACJI (2026-10-07): 'e' w oknie szczegolow (Enter na F3) oddaje
# terminal oknom edit-relation; bez okna 'e' jest tekstem linii polecen.
A="$(act down,enter,e)"
if grep -Eq "zfs-backup.sh'? edit-relation lab-ct201 --ask\$" "$XL"; then
    ok "akcje: 'e' w oknie relacji na F3 oddaje terminal oknom zmiany (edit-relation NAZWA --ask)"
else
    bad "akcje: e -> edit-relation --ask" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
# U65: 's' i 'c' w oknie relacji -- zapis jako szablon i reczna edycja WPROST (EDIT_DO), bez karty zmian.
A="$(act down,enter,s)"; XS="$(cat "$XL")"
A="$(act down,enter,c)"; XC="$(cat "$XL")"
if printf '%s' "$XS" | grep -Eq "^EDIT_DO=zapisz .*zfs-backup.sh'? edit-relation lab-ct201 --ask\$"    && printf '%s' "$XC" | grep -Eq "^EDIT_DO=config .*zfs-backup.sh'? edit-relation lab-ct201 --ask\$"; then
    ok "akcje: 's'/'c' w oknie relacji -> edit-relation --ask z EDIT_DO=zapisz/config (U65)"
else
    bad "akcje: s/c w oknie relacji" "$XS" "$XC"
fi
A="$(act down,enter)"
# Odzysk jest na F4 Kopie; U65: w stopce 'e zmień', 's' i 'c'.
if has "$A" 'e zmienia   s jako szablon   c edycja ręczna   Esc zamyka'; then
    ok "akcje: ...okno relacji mowi o tym w stopce ('e zmień'), bez 'p przywróć'"
else
    bad "akcje: stopka okna relacji bez 'e'" "$(printf '%s' "$A" | tail -3)"
fi
# DOKOŃCZ (paczka A finiszu, 2026-10-18): relacja nie-aktywna dostaje w oknie 'd' =
# następny krok cyklu jako zwykłe potwierdzenie; 't' go wykonuje. Aktywna -- nic.
A="$(act enter)"
B="$(act enter,d)"
if has "$A" 'd dokańcza   e zmienia' && has "$B" 'POTWIERDZENIE: Dokończ relację duplikat' && has "$B" 'seed duplikat --yes' && [ ! -s "$XL" ]; then
    ok "akcje: okno relacji w stanie '1. kopia' -- stopka 'd dokończ', 'd' pokazuje 'seed NAZWA --yes' i niczego nie uruchamia"
else
    bad "akcje: d dokończ (podgląd)" "$(printf '%s' "$A" | tail -3)" "$B"
fi
A="$(act enter,d,t)"
if grep -Eq "zfs-backup.sh'? seed duplikat --yes\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "akcje: ...'t' wykonuje dokładnie ten krok (seed duplikat --yes)"
else
    bad "akcje: d dokończ + t" "$(cat "$XL")"
fi
A="$(act down,enter,d)"
if [ ! -s "$XL" ] && ! has "$A" 'POTWIERDZENIE' && ! has "$A" 'd dokańcza'; then
    ok "akcje: na relacji AKTYWNEJ 'd' nic nie robi i stopka o nim nie mówi"
else
    bad "akcje: d na aktywnej" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(act down,e)"
if [ ! -s "$XL" ]; then
    ok "akcje: ...bez okna 'e' jest tekstem linii polecen i niczego nie uruchamia"
else
    bad "akcje: 'e' bez okna uruchomil czasownik" "$(cat "$XL")"
fi
A="$(act end,del)"
if grep -Eq "delete-relation 192.168.28.99 --ask\$" "$XL" && ! has "$A" 'jest już usunięta'; then
    ok "akcje: Del dziala takze na rekordzie 'removed' -- tam znaczy 'zwolnij nazwe / posprzataj reszte'"
else
    bad "akcje: Del na removed" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
# DZIENNIK DLA Del/Ins (owner note 5): w trybie --exec-log NIC sie nie
# uruchamia, wiec sciezka rzeczywista (run_dialog/run_wizard poza atrapa) nie
# jest tu do sprawdzenia na zywo -- jednostkowo: start_verb_log() produkuje
# "~/.zfs-tui/<verb>-<stamp>.log" i wypisuje doń naglowek "$ <komenda>".
LOGTMP="$(mktemp -d)"
LOGPATH="$(HOME="$LOGTMP" "$PY" -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('zfstui', sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
ui = mod.UI.__new__(mod.UI)
print(mod.UI.start_verb_log(ui, 'delete-relation', 'zfs-backup.sh delete-relation nazwa --ask'))
" "$TUI")"
LOGPATH="${LOGPATH%$'\r'}"   # print() pythona na Windowsie konczy linie CRLF
case "$LOGPATH" in
    *.zfs-tui[/\\]delete-relation-*.log)   # Windowsowy python zwraca C:\...\.zfs-tui\..., Linux /tmp/.../.zfs-tui/...
        if [ -f "$LOGPATH" ] && head -1 "$LOGPATH" | grep -qF '$ zfs-backup.sh delete-relation nazwa --ask'; then
            ok "linia: start_verb_log() (uzywana przez Del/Ins) daje ~/.zfs-tui/delete-relation-<stamp>.log z naglowkiem '\$ komenda'"
        else
            bad "linia: naglowek dziennika" "$(cat "$LOGPATH" 2>/dev/null)"
        fi ;;
    *) bad "linia: sciezka dziennika Del/Ins" "$LOGPATH" ;;
esac
rm -rf "$LOGTMP"
# Stary kreator curses zostal USUNIETY 2026-09-21 (polecenie wlasciciela): dwie
# drogi do tego samego ekranu to dwie drogi do utrzymania. Flagi --wizard juz nie
# ma, a Ins zawsze oddaje terminal czasownikowi new-relation -- pinowane wyzej.
if ! "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --wizard curses >/dev/null 2>&1 \
   && ! grep -q 'wizard_open\|WIZ_STEPNO' "$TUI"; then
    ok "akcje: starego kreatora curses NIE MA -- ani flagi --wizard, ani jego kodu w pliku"
else
    bad "akcje: resztki starego kreatora" "$(grep -c 'wiz_\|WIZ_' "$TUI") odwolan"
fi
# ============================================================================
# OKNO RELACJI (Enter)
# ============================================================================
# RYTM PER SZCZEBEL (2026-10-07): okno bralo rytm i retencje tylko z PIERWSZEGO
# szablonu sekcji i nie znalo pol send_schedule_<szablon> / prune_schedule_<szablon>
# (rozrzut U2/K3) -- pve11 na pve10 mowilo "co: 1 * * * *" przy pobraniu o :56.
TCFG="$(mktemp)"
"$PY" - "$P10/show-config.json" "$TCFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["templates"] += [
    {"name": "profile__m__hourly", "fields": {"send_schedule": "1 * * * *", "prefix": "automated_hourly_", "keep": "24", "prune_schedule": "21 * * * *"}},
    {"name": "profile__m__daily",  "fields": {"send_schedule": "11 1 * * *", "prefix": "automated_daily_", "keep": "7", "prune_schedule": "31 1 * * *"}},
    {"name": "profile__m__src_hourly", "fields": {"keep": "12", "prune_schedule": "21 * * * *"}},
    {"name": "profile__m__src_daily",  "fields": {"keep": "3", "prune_schedule": "31 1 * * *"}}]
d["sections"] = [
    {"kind": "dataset", "name": "hdd/b/x", "fields": {"use_template": "profile__m__hourly,profile__m__daily",
        "send_schedule_profile__m__hourly": "56 * * * *", "send_schedule_profile__m__daily": "6 2 * * *",
        "src": "u@h:hdd/x", "pair_label": "lab-ct201"}},
    {"kind": "prune", "name": "u@h:hdd/x", "fields": {"use_template": "profile__m__src_hourly,profile__m__src_daily",
        "prune_schedule_profile__m__src_hourly": "36 * * * *", "prune_schedule_profile__m__src_daily": "46 2 * * *"}}]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
WT="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --config "$TCFG" --screen relacje --keys down,enter --height 80 --width 200 2>&1)"
rm -f "$TCFG"
if has "$WT" 'co: co godzinę (:56)   migawki automated_hourly_*   trzyma 24' && has "$WT" 'co: co dobę 02:06   migawki automated_daily_*   trzyma 7' \
   && has "$WT" 'trzyma 12   co: co godzinę (:36)' && has "$WT" 'trzyma 3   co: co dobę 02:46' && ! has "$WT" 'co: co godzinę (:01)'; then
    ok "okno: rytm i retencja KAZDEGO szczebla, z polami szczebla sekcji (send_/prune_schedule_<szablon>) przed szablonem"
else
    bad "okno: rytm per szczebel" "$(printf '%s' "$WT" | grep -E 'pobranie|prune|co:' | head -8)"
fi
# X27 (przejscie na zywo, pve10 2026-10-23): pola szczebla pod KROTKA nazwa
# (send_schedule_hourly), porzadki u celu w samej sekcji datasetu, porzadki u zrodla
# po szczeblu z szablonow. Okno mowilo "co godzinę (:01)" przy pobraniu o :13, bez
# porzadkow u celu i z jednym szczeblem porzadkow u zrodla.
TCFG="$(mktemp)"
"$PY" - "$P10/show-config.json" "$TCFG" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["templates"] += [
    {"name": "profile__relacja-m__hourly", "fields": {"send_schedule": "1 * * * *", "prefix": "automated_hourly_", "retain": "-H24", "prune_schedule": "21 * * * *"}},
    {"name": "profile__relacja-m__daily",  "fields": {"send_schedule": "11 1 * * *", "prefix": "automated_daily_", "retain": "-D7", "prune_schedule": "31 1 * * *"}},
    {"name": "profile__relacja-m__src_hourly", "fields": {"retain": "-H24", "prune_schedule": "21 * * * *"}},
    {"name": "profile__relacja-m__src_daily",  "fields": {"retain": "-D7", "prune_schedule": "31 1 * * *"}}]
d["sections"] = [
    {"kind": "dataset", "name": "hdd/b/x", "fields": {"use_template": "profile__relacja-m__hourly,profile__relacja-m__daily",
        "side": "target", "src": "u@h:hdd/x", "pair_label": "lab-ct201",
        "send_schedule_hourly": "13 * * * *", "send_schedule_daily": "23 1 * * *",
        "prune_schedule_hourly": "33 * * * *", "prune_schedule_daily": "43 1 * * *"}},
    {"kind": "prune", "name": "u@h:hdd/x", "fields": {"use_template": "profile__relacja-m__src_hourly,profile__relacja-m__src_daily", "side": "source"}}]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
WT="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --config "$TCFG" --screen relacje --keys down,enter --height 80 --width 200 2>&1)"
rm -f "$TCFG"
if has "$WT" 'co: co godzinę (:13)   migawki automated_hourly_*' && has "$WT" 'co: co dobę 01:23   migawki automated_daily_*' \
   && hasE "$WT" 'lokalny prune +trzyma 24 godz\.   co: co godzinę \(:33\)' && hasE "$WT" 'lokalny prune +trzyma 7 dni   co: co dobę 01:43' \
   && hasE "$WT" 'zdalny prune +trzyma 24 godz\.   co: co godzinę \(:21\)' && hasE "$WT" 'zdalny prune +trzyma 7 dni   co: co dobę 01:31' \
   && ! has "$WT" 'co: co godzinę (:01)'; then
    ok "okno: X27 -- pola szczebla pod krotka nazwa, porzadki u celu z sekcji datasetu, porzadki u zrodla po szczeblu"
else
    bad "okno: X27 rytm per szczebel" "$(printf '%s' "$WT" | grep -E 'pobranie|prune|co:' | head -8)"
fi
W="$(screen relacje down,enter --height 80)"
if has "$W" '╔═ Relacja lab-ct201: [Opis]  Config   ←/→ ═'; then
    ok "okno: Enter na wierszu otwiera okno relacji na wierzchu"
else
    bad "okno: otwarcie" "$W"
fi
if hasE "$W" 'Cele [(]1[)] +hdd/backups/192.168.28.99/hdd/lab/ct-201' && ! has "$W" 'Lądowisk' && ! hasE "$W" '║ Cel  ' && hasE "$W" 'Źródła [(]1[)] +pve9:hdd/lab/ct-201' \
        && has "$W" 'co obejmuje' && has "$W" 'jak długo trzyma' && has "$W" 'czy działa' && ! has "$W" '║ komendy' \
        && ! has "$W" '── CONFIG ' && ! has "$W" '── CRON ' && hasE "$W" 'Drugi host +pve9' && ! has "$W" 'endpoint'; then
    ok "okno: zakladka Opis -- zrodla z rekordu, JEDEN wiersz 'Cele (N)' (R5-3), grupy pytaniami operatora, 'Drugi host', bez komend i bez configu (U114)"
else
    bad "okno: zakres/Opis" "$W"
fi
W2="$(screen relacje down,enter --height 60)"
if ! has "$W2" 'zfs-backup.sh pause-client' && has "$W2" 'Relacja lab-ct201: [Opis]  Config   ←/→ ═'; then
    ok "okno: bez listy komend CLI (U114) -- czynnosci pod klawiszami na ramce, ←/→ podpisane"
else
    bad "okno: komendy/ramka (U114)" "$W2"
fi
# JEDNO OKNO (R4-7, zamiast zakladek R3-2): szczegoly, pod nimi CONFIG, potem
# CRON -- w tej kolejnosci. LINIE CRONA PO ETYKIECIE (linia snapget dla pobrania
# nazywa zdalne zrodlo i RODZICA ladowiska, nigdy samo ladowisko -- dopasowanie
# po zakresie jej nie widzialo, zmierzone na pve10 2026-09-09; klucz drugi:
# -L <etykieta>) sa w sekcji CRON.
WCFG="$(screen relacje down,enter,right --height 200)"
LCFG=$(printf '%s\n' "$WCFG" | grep -n '── CONFIG ' | head -1 | cut -d: -f1)
LCRN=$(printf '%s\n' "$WCFG" | grep -n '── CRON ' | head -1 | cut -d: -f1)
WCBK="$(screen relacje down,enter,right,right --height 200)"
if [ -n "$LCFG" ] && [ -n "$LCRN" ] && [ "$LCFG" -lt "$LCRN" ] && has "$WCFG" 'Relacja lab-ct201: Opis  [Config]' \
   && ! has "$WCFG" 'co obejmuje' && has "$WCBK" 'Relacja lab-ct201: [Opis]  Config' && has "$WCBK" 'co obejmuje'; then
    ok "okno: zakladka Config (→) -- CONFIG, potem CRON, bez opisu; drugie → wraca na Opis (U114)"
else
    bad "okno: zakladka Config" "config=$LCFG cron=$LCRN" "$WCFG"
fi
if has "$WCFG" '── CONFIG ' && has "$WCFG" '[dataset:' && has "$WCFG" 'plik: /etc/zfs-snapshot-all/jobs.pve10.conf' \
        && ! has "$WCFG" 'tylko do odczytu -- zmiana relacji'; then
    ok "okno: sekcja CONFIG -- sekcje configu werbatim (klucz=wartosc) z show-config, plik u gory; bez dopisku o zmianie relacji (wlasciciel 2026-10-19: podglad wystarczy)"
else
    bad "okno: sekcja CONFIG" "$WCFG"
fi
WC="$WCFG"
if has "$WC" '── CRON ' && has "$WC" 'snapget.sh -m' && has "$WC" '-L lab-ct201' && has "$WC" 'delsnaps.sh -G -R -L'; then
    ok "okno: sekcja CRON pokazuje linie snapget (po etykiecie -L), delsnaps i monitor -- to, co host naprawde wykona"
else
    bad "okno: sekcja CRON" "$WC"
fi
# R5-5 (wlasciciel 2026-09-25): kazdy naglowek ze SWOIMI liniami. Drabina GFS
# (keep_hourly..keep_monthly, jedna linia delsnaps) to jeden naglowek, a jej
# delsnaps i straznik stoja pod nim -- nie pod transferem i nie we "wspolnych".
# 160 kolumn: przy 80 naglowek grupy zawija sie w kilka linii.
WCG="$(screen relacje down,enter,right --width 160 --height 300 | sed -n '/── CRON /,/konto:/p')"
_lh=$(printf '%s\n' "$WCG" | grep -n '← 192.168.28.99  30 \* \* \* \*' | head -1 | cut -d: -f1)
_ls=$(printf '%s\n' "$WCG" | grep -n 'snapget.sh -m "automated_hourly_"' | head -1 | cut -d: -f1)
_lp=$(printf '%s\n' "$WCG" | grep -n 'prune  50 \* \* \* \*  keep_hourly -H24, keep_daily -D7, keep_weekly -W4, keep_monthly -M12' | head -1 | cut -d: -f1)
_ld=$(printf '%s\n' "$WCG" | grep -n 'delsnaps.sh -G -R -L lab-ct201' | head -1 | cut -d: -f1)
_lm=$(printf '%s\n' "$WCG" | grep -n 'check-snap-age.sh -R -L lab-ct201' | head -1 | cut -d: -f1)
if [ -n "$_lh" ] && [ -n "$_ls" ] && [ -n "$_lp" ] && [ -n "$_ld" ] && [ -n "$_lm" ]    && [ "$_lh" -lt "$_ls" ] && [ "$_ls" -lt "$_lp" ] && [ "$_lp" -lt "$_ld" ] && [ "$_ld" -lt "$_lm" ]    && ! printf '%s\n' "$WCG" | grep -q 'wspólne'; then
    ok "okno: CRON wg zakresow -- transfer pod swoim naglowkiem, drabina GFS jednym naglowkiem z delsnaps i straznikiem pod nim (R5-5)"
else
    bad "okno: CRON wg zakresow" "naglowek=$_lh snapget=$_ls prune=$_lp delsnaps=$_ld straznik=$_lm" "$WCG"
fi
# Relacja W ZASIEWIE (bez pliku configu) -- Config ma powiedziec to, nie
# pokazac cudzy config z fikstury.
WCFGSEED="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --screen relacje --keys enter,right --height 80 --width 100 2>&1)"
if has "$WCFGSEED" 'configu jeszcze nie ma -- powstanie przy aktywacji' && has "$WCFGSEED" 'zfs-backup.sh activate duplikat'; then
    ok "okno: CONFIG relacji bez zainstalowanego configu (seeding) mowi to, nie zgaduje"
else
    bad "okno: CONFIG relacji w zasiewie" "$WCFGSEED"
fi
WP="$(screen relacje down,down,down,down,enter,right --height 260)"
if has "$WP" '── CONFIG ' && has "$WP" '[dataset:hdd/backups/192.168.28.99/hdd/lab/vm-101]' \
        && has "$WP" 'send_schedule = 24 * * * *' && has "$WP" 'src = zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' \
        && has "$WP" '[prune:hdd/backups/192.168.28.99/hdd/lab/vm-101]' && has "$WP" 'prune_schedule = 44 * * * *' \
        && has "$WP" '[template:profile__default__keep_monthly]' && has "$WP" 'retain = -M12'; then
    ok "okno: CONFIG relacji -- sekcje [dataset:]/[prune:] i szablony UZYTE (use_template), werbatim z show-config"
else
    bad "okno: CONFIG -- sekcje relacji lab-vm101" "$WP"
fi
WS="$(screen relacje enter --height 60)"
if has "$WS" '[Opis]  Config   ←/→' && has "$WS" 'd dokańcza   e zmienia' && ! has "$WS" '║   zfs-backup.sh activate duplikat'; then
    ok "okno: relacja w trakcie pierwszej kopii -- 'd dokańcza' na ramce, bez listy komend w opisie (U114)"
else
    bad "okno: relacja w trakcie pierwszej kopii (U114)" "$WS"
fi
WPZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down,enter --height 120 2>&1)"
if ! has "$WPZ" 'resume-client lab-srv-b' && ! has "$WPZ" 'pause-client lab-srv-b' && has "$WPZ" 'Relacja lab-srv-b: [Opis]'; then
    ok "okno: relacja wstrzymana -- bez listy komend w opisie (U114; wznowienie: F7 na F3)"
else
    bad "okno: relacja wstrzymana (U114)" "$WPZ"
fi
WE="$(screen relacje down,enter,esc)"
if has "$WE" 'Relacje na kolektorze pve10' && ! has "$WE" '╔═ Relacja lab-ct201'; then
    ok "okno: Esc zamyka okno i wraca do listy"
else
    bad "okno: Esc" "$WE"
fi
# Zakladka Config (U114) jest dluzsza niz ekran -- tam stopka liczy wiersze.
if hasE "$(screen relacje down,enter,right)" 'Esc zamyka +[0-9]+-[0-9]+ z [0-9]+'; then
    ok "okno: stopka mowi, jak wyjsc i ile jest do przewiniecia"
else
    bad "okno: stopka" "$W"
fi

# ============================================================================
# F4 Historia (ekran "transfery": lista transferow, F7 chowa usuniete, odswiezanie na zywo)
# ZNIESIONA razem z F11 Odzysk -- jej testy (ramki, wiersz transferu, panel, F7 chowa/pokazuje,
# Enter, kolumna Kiedy starszego wpisu) usuniete; biegi sa na F2 Przebiegi, kopie na F4 Kopie.
# ============================================================================
# R4-2: LITERA TO TEKST. 'u' w rundzie 3 bylo zielone w tescie i martwe na
# zywo: --keys podawal 'u' prosto do UI.key, a petla curses oddaje je linii
# polecen. --keys idzie teraz ta sama droga (live_key_name), wiec 'u' ma NIC
# nie zrobic i stanac w linii polecen (tu na F2 Przebiegi, gdzie 'u' nie jest skrotem).
TUL="$(screen zadania u --width 160)"
if has "$TUL" 'Przebiegi na pve10' && has "$TUL" '$ u_ '; then
    ok "przebiegi: 'u' to TEKST linii polecen, nie skrot (R4-2: droga --keys = droga petli curses)"
else
    bad "przebiegi: 'u' jako tekst" "$TUL"
fi
# R4-1/R4-2 PRZEZ PRAWDZIWA PETLE CURSES (pty), nie przez --keys: runda 3
# miala 'u' i 's' zielone tutaj i martwe na zywo. Klawisze ida jako bajty
# terminala (ESC [ 18 ~ = F7, ESC [ 19 ~ = F8); kazdy blok to to, co program narysowal po nim.
PK="$("$PY" "$REPO/test/tui/pty-keys.py" "$TUI" 's,F8,F3,F4,u,ctrl-r' -- --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" 2>&1)"; PKRC=$?
pkb() { printf '%s\n' "$PK" | awk -v k="=== $1" -v n="$2" '$0 ~ /^=== / { i++; on = ($0 == k && i == n) ; next } on'; }
if [ "$PKRC" -eq 2 ]; then
    echo "SKIP pty: brak modulu pty (Windows) -- klawisze przez petle curses sprawdza CI"
elif has "$(pkb s 2)" 's_' && ! has "$(pkb s 2)" 'tylko nadchodzące' && has "$(pkb F8 3)" 'tylko nadchodzące' \
     && has "$(pkb F4 5)" 'Kopie na' && ! has "$(pkb F4 5)" 'POTWIERDZENIE' \
     && has "$(pkb u 6)" 'u_' && has "$(pkb ctrl-r 7)" 'odświeżam'; then
    # U85: F7 na Kopiach to teraz Przeglądaj (oddaje terminal prawdziwemu `browse`) -- w petli pty
    # tego klawisza nie wciskamy; jego droge sprawdza 'odzysk: F7 na Kopiach' przez --exec-log.
    ok "pty: 's' i 'u' to tekst linii, F8 chowa wykonane na F2 Przebiegi (tytul 'tylko nadchodzące'), F4 na F3 otwiera Kopie (petla curses, R4-1/R4-2)"
else
    bad "pty: klawisze przez petle curses" "$PK"
fi
# F11 / F4 / F12 / Tab PRZEZ PETLE CURSES (2026-10-18): F11 (ESC [ 23 ~) jest WOLNY -- nic nie
# otwiera; F4 otwiera Kopie, Tab przenosi do linii polecen (strzalka w gore = historia),
# ESC [ 24 ~ (F12) konczy program.
PK2="$("$PY" "$REPO/test/tui/pty-keys.py" "$TUI" 'F11,F4,tab,F12' -- --offline --utf8 --now "$NOW" $ALL 2>&1)"; PK2RC=$?
pk2() { printf '%s\n' "$PK2" | awk -v k="=== $1" '$0 ~ /^=== / { on = ($0 == k); next } on'; }
if [ "$PK2RC" -eq 2 ]; then
    echo "SKIP pty F11/F12: brak modulu pty (Windows) -- sprawdza CI"
elif ! has "$(pk2 F11)" 'Kopie na' && ! has "$(pk2 F11)" 'Odzysk danych' \
     && has "$(pk2 F4)" 'Kopie na pve10' \
     && printf '%s\n' "$PK2" | grep -qx '=== exited'; then
    ok "pty: F11 (ESC[23~) niczego nie otwiera, F4 otwiera Kopie, Tab, F12 (ESC[24~) konczy program rc=0 (petla curses)"
else
    bad "pty: F11/F12 przez petle curses" "rc=$PK2RC" "$PK2"
fi
# Odswiez: F9 -> F5 (R4-2) -> Ctrl-R (2026-10-09: F5 to ekran Szablony, uwaga 24).
# Szerokosc 200: pelny zapis paska F2 (z 'Schowaj wykonane' i 'Grupuj po relacji') ma 165 znakow,
# a 'Ctrl-R Odśwież' dochodzi dopiero, gdy zostaje 16 kolumn zapasu -- przy 160 pasek jest skrocony.
TR="$(screen zadania ctrl-r --width 200)"
if has "$TR" 'odświeżono' && has "$TR" 'Ctrl-R Odśwież' && ! has "$TR" 'F5 Odśwież' && has "$TR" 'F5 Szablony'; then
    ok "listwa: Ctrl-R odswieza i tak jest podpisane; F5 to Szablony"
else
    bad "listwa: Ctrl-R odswiez" "$TR"
fi
# U90: Ctrl-O Konsola dochodzi do paska ZA 'Ctrl-R Odśwież', gdy zostaje 16 kolumn zapasu (przy 200
# pasek F2 (pelny zapis ~165 znakow) konczy sie na Ctrl-R przy 190); pomoc F1 ma wiersz o Ctrl-O.
TO="$(screen zadania "" --width 240 | tail -1)"; TO2="$(screen zadania "" --width 120 | tail -1)"
if has "$TO" 'Ctrl-R Odśwież  Ctrl-O Konsola' && ! has "$TO2" 'Ctrl-O' \
   && has "$H1" "Ctrl-O            konsola pod oknami"; then
    ok "listwa: Ctrl-O Konsola stoi za Ctrl-R Odśwież, gdy jest miejsce (240), nie przy 120; pomoc F1 opisuje Ctrl-O (U90)"
else
    bad "listwa: Ctrl-O Konsola" "240: $TO" "190: $TO2"
fi
# F5 SZABLONY (uwaga 24): tabela Nazwa | Rodzaj | Sposob | Trzyma | Uzyty, panel ze
# szczeblami; Ins = nowy NA PODSTAWIE zaznaczonego, Enter+'e' = zmiana, Del = usun --
# kazde oddaje terminal oknom tui/template.sh przez czasownik --ask.
SZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --screen szablony --width 160 --height 30 2>&1)"
if hasE "$SZ" '║ d7h24 +fabryczny +N najnowszych +24 godz., 7 dni +0 ' && has "$SZ" 'Szablony retencji (17)' \
   && hasE "$SZ" 'Jak liczy +' && has "$SZ" '[Szczeble]  Używają' && has "$SZ" 'Ins nowy z zaznaczonego' && has "$SZ" 'F5 Szablony'; then
    ok "szablony: F5 -- tabela (nazwa, rodzaj, sposob, trzyma, uzyty), panel 'Jak liczy', zakladki Szczeble/Uzywaja, stopka z Ins/Del"
else
    bad "szablony: ekran F5" "$SZ"
fi
sact() {   # <keys> -> ekran F5; dziennik komend w $XL (wyzerowany)
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --exec-log "$XL" --screen szablony --keys "$1" 2>&1
}
A1=$(sact down,ins >/dev/null; cat "$XL"); B1=$(sact down,enter,e >/dev/null; cat "$XL"); C1=$(sact down,del >/dev/null; cat "$XL")
if printf '%s' "$A1" | grep -Eq "save-profile --ask '?--from=d30'?\$" && printf '%s' "$B1" | grep -Eq "save-profile --ask '?--edit=d30'?\$" \
   && printf '%s' "$C1" | grep -Eq "delete-profile d30 --ask\$"; then
    ok "szablony: Ins = save-profile --ask --from=ZAZNACZONY, Enter+'e' = --edit=ZAZNACZONY, Del = delete-profile ZAZNACZONY --ask"
else
    bad "szablony: akcje" "ins: $A1" "e: $B1" "del: $C1"
fi
TF="$(screen zadania F4)"
if has "$TF" '╔═ Kopie na pve10' && ! has "$TF" '[F4'; then
    ok "kopie: F4 z innego ekranu przelacza (aktywne okno na pasku kolorem, bez nawiasow)"
else
    bad "kopie: F4" "$TF"
fi
# (Enter na wierszu Historii transferow i kolumna Kiedy starszego wpisu -- usuniete razem z F4 Historia.)

# ============================================================================
# F5 MONITOR ZNIESIONY (wlasciciel, wariant b, 2026-09-24): F2 i F5 pokazywaly
# ten sam werdykt "Kopie" i wlasciciel nie widzial roznicy. Ekran monitor
# zniknal; jego dodatkowa trescia (harmonogram straznika, progi, straznik bez
# zadania) przejmuje panel F2 -- testy nizej (blok F2 i "wyglad") sprawdzaja to.
# ============================================================================
Z4W="$(screen zadania)"
# F5 wrocilo 2026-10-09 jako ekran Szablony (uwaga 24) -- Monitora nadal nie ma.
if ! has "$Z4W" 'Monitor' && hasE "$Z4W" 'F5 Szablony|5Szablony|5Szabl'; then
    ok "F5: ekran domyslny (F2) nie wspomina Monitora; F5 to dzis Szablony"
else
    bad "F5: pozostalosc na ekranie" "$Z4W"
fi
EMSC="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen monitor 2>&1)"; EMRC=$?
if [ "$EMRC" -ne 0 ] && has "$EMSC" 'monitor'; then
    ok "F5: '--screen monitor' nie jest juz poprawnym wyborem argparse (choices = SCREENS)"
else
    bad "F5: --screen monitor nadal dziala" "$EMSC"
fi

# RELACJA LOKALNA na F3 (2026-10-09): rekord z mode=local i bez peera. Wiersz mowi
# "<host> → tutaj" i "lokalna", panel zamiast Peer/Endpoint pokazuje zrodlo i cel.
LOKD="$(mktemp -d)"
"$PY" - "$P10" "$LOKD" <<'PYEOF'
import json, sys
p, d = sys.argv[1], sys.argv[2]
st = json.load(open(p + "/status.json", encoding="utf-8"))
r = dict(st["relations"][0])
r.update({"name": "lok", "state": "active", "mode": "local", "peer_host": "", "pair_label": "lok",
          "client_target": "hdd/kopie", "sources": ["rpool/data"], "managed_datasets": ["hdd/kopie/rpool/data"],
          "active_endpoint": "", "installed_endpoint": "", "source_profile": ""})
st["relations"] = [r] + st["relations"]
json.dump(st, open(d + "/status.json", "w", encoding="utf-8"))
j = json.load(open(p + "/list-jobs.json", encoding="utf-8"))
n = dict([x for x in j["jobs"] if x.get("section_kind") == "dataset"][0])
n.update({"label": "lok", "direction": "local", "scope": "dataset:rpool/data", "schedule": "1 * * * *"})
j["jobs"].append(n)
json.dump(j, open(d + "/list-jobs.json", "w", encoding="utf-8"))
PYEOF
LOK="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$LOKD/status.json" --jobs "$LOKD/list-jobs.json" --monitors "$P10/monitor.json" --screen relacje --width 120 --height 30 2>&1)"
if hasE "$LOK" '^║ lok +kopia lokalna +lokalnie +działa ' && hasE "$LOK" 'Źródło +rpool/data' && hasE "$LOK" 'Cel +hdd/kopie' \
   && ! printf '%s\n' "$LOK" | grep -E 'Drugi host' | grep -q .; then
    ok "relacje: relacja lokalna -- 'lokalnie', typ 'kopia lokalna', w panelu zrodlo i cel zamiast drugiego hosta"
else
    bad "relacje: relacja lokalna" "$LOK"
fi
# Ten sam ekran po angielsku (pve2, 2026-10-29): kolumna Direction mowila "lokalnie".
LOKE="$(ZFS_TUI_LANG=en "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$LOKD/status.json" --jobs "$LOKD/list-jobs.json" --monitors "$P10/monitor.json" --screen relacje --width 120 --height 30 2>&1)"
if hasE "$LOKE" '^║ lok +local copy +local +' && ! has "$LOKE" 'lokalnie'; then
    ok "relacje: relacja lokalna po angielsku -- kierunek 'local', nie 'lokalnie'"
else
    bad "relacje: relacja lokalna po angielsku" "$(printf '%s\n' "$LOKE" | grep -E 'lok ' | head -3)"
fi
# MIGAWKI LOKALNE (nazwy wlasciciela 2026-10-18): ta sama relacja lokalna BEZ celu to
# "migawki lokalne", nie "kopia lokalna" -- typ mowi CO, kierunek GDZIE.
"$PY" - "$LOKD" <<'PYEOF2'
import json, sys
d = sys.argv[1]
st = json.load(open(d + "/status.json", encoding="utf-8"))
st["relations"][0]["client_target"] = ""
json.dump(st, open(d + "/status.json", "w", encoding="utf-8"))
PYEOF2
LOKN="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$LOKD/status.json" --jobs "$LOKD/list-jobs.json" --monitors "$P10/monitor.json" --screen relacje --width 120 --height 30 2>&1)"
if hasE "$LOKN" '^║ lok +migawki lokalne +lokalnie +działa ' && hasE "$LOKN" 'Cel +ten sam dataset \(migawki'; then
    ok "relacje: relacja lokalna bez celu -- typ 'migawki lokalne' (nie 'kopia lokalna'), Cel 'ten sam dataset (migawki, bez kopii)' zamiast '?'"
else
    bad "relacje: migawki lokalne" "$LOKN"
fi
rm -rf "$LOKD"

# RELACJA SNAPONLY na F3/F2 (REV-20261017-152 runda 3): rekord mode=snaponly, zadania
# z list-jobs o section_kind/direction "snaponly" (jak pisze je czytelnik od rundy
# 3) i zdalny monitor z wzorcem z koncowym '_'. Wiersz: "migawki na <peer>", typ
# "migawki"; panel: "Kopia: brak", "Migawki" (harmonogram, rodzina) i werdykt
# monitora jako "Migawki" zamiast "Kopie"; okno relacji bez 'e'/'p'.
SOD="$(mktemp -d)"
"$PY" - "$P10" "$SOD" <<'PYEOF'
import json, sys
p, d = sys.argv[1], sys.argv[2]
st = json.load(open(p + "/status.json", encoding="utf-8"))
r = dict(st["relations"][0])
r.update({"name": "som", "state": "active", "mode": "snaponly", "peer_host": "10.0.0.9", "pair_label": "som",
          "client_target": "", "active_endpoint": "10.0.0.9:22", "installed_endpoint": "10.0.0.9:22",
          "profile": "d7h24", "source_profile": "", "paused_local": False})
st["relations"] = [r] + st["relations"]
json.dump(st, open(d + "/status.json", "w", encoding="utf-8"))
j = json.load(open(p + "/list-jobs.json", encoding="utf-8"))
base = dict([x for x in j["jobs"] if x.get("section_kind") == "dataset"][0])
for tier, pref, sch in (("snaponly__som__hourly", "pve10_automated_hourly_", "39 * * * *"),
                        ("snaponly__som__daily", "pve10_automated_daily_", "49 1 * * *")):
    n = dict(base)
    n.update({"label": "som", "section_kind": "snaponly", "direction": "snaponly", "peer": "10.0.0.9",
              "scope": "zfsbackup-pve10@10.0.0.9:hdd/solab", "other_end": "", "tier": tier,
              "prefix": pref, "pattern": "", "schedule": sch, "cron_lines": []})
    j["jobs"].append(n)
json.dump(j, open(d + "/list-jobs.json", "w", encoding="utf-8"))
m = json.load(open(p + "/monitor.json", encoding="utf-8"))
mm = dict(m["monitors"][0])
mm.update({"label": "som", "datasets": ["zfsbackup-pve10@10.0.0.9:hdd/solab"], "pattern": "pve10_automated_hourly_",
           "warn": "90m", "crit": "150m", "verdict": "OK", "rc": 0, "reason": "", "parsed": True, "recursive": False})
m["monitors"].append(mm)
md = dict(mm); md.update({"pattern": "pve10_automated_daily_", "warn": "30h", "crit": "48h"})
m["monitors"].append(md)
json.dump(m, open(d + "/monitor.json", "w", encoding="utf-8"))
PYEOF
SOA="--status $SOD/status.json --jobs $SOD/list-jobs.json --monitors $SOD/monitor.json"
SO3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen relacje --width 120 --height 34 2>&1)"
SO3Z="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen relacje --width 120 --height 34 --keys tab,right 2>&1)"
if hasE "$SO3" '^║ som +migawki zdalne +→ som +działa ' && hasE "$SO3" 'Kopia +brak -- migawki i ich' \
   && hasE "$SO3Z" 'migawka +pve10_automated_daily +co dobę 01:49' && hasE "$SO3Z" 'migawka +pve10_automated_hourly +co godzinę' \
   && ! printf '%s\n' "$SO3" | grep -E '^║ som .*(pve10<|←)' | grep -q .; then
    ok "relacje: relacja snaponly -- '→ <peer>', typ 'migawki zdalne', w panelu 'Kopia: brak', w zakladce Zadania migawki z rodzina i harmonogramem"
else
    bad "relacje: relacja snaponly" "$SO3" "$SO3Z"
fi
# Dolny panel (wlasciciel 2026-10-18, "nie rozumiem tej listy"): bez kopii wiersz to
# sam dataset i host, nie surowy zakres "konto@host:ds -> bez kopii".
if hasE "$SO3" '^║ hdd/solab   na som +aktualne' && has "$SO3" 'som: [Datasety]  Zadania' \
   && hasE "$SO3" '^║ Dataset +Migawki +Szczeble' && ! printf '%s\n' "$SO3" | grep -qE 'zfsbackup-pve10@|bez kopii +aktualne'; then
    ok "relacje: dataset snaponly -- wiersz 'dataset   na <host>' z monitorem 'aktualne', kolumny Dataset/Migawki"
else
    bad "relacje: monitor pary snaponly" "$SO3"
fi
SOE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen relacje --width 120 --height 34 --keys enter 2>&1)"
if has "$SOE" 'e zmienia   s jako szablon   c edycja ręczna   Esc zamyka' && ! has "$SOE" 'p przywróć' && ! hasE "$SOE" 'Zmiana +'; then
    ok "relacje: okno relacji snaponly -- 'e zmień' jak w kazdej relacji, bez 'p przywróć' (nie ma kopii)"
else
    bad "relacje: stopka okna snaponly" "$SOE"
fi
# Wlasciciel 2026-10-18: "co kopiuje" nie pasowalo do migawek, a "Cel ?" mylil --
# celem migawek jest ten sam dataset.
if has "$SOE" 'co obejmuje' && ! has "$SOE" 'co kopiuje' && hasE "$SOE" 'Cel +ten sam dataset \(migawki, bez kopii\)' \
   && ! hasE "$SOE" 'Cel +\?'; then
    ok "relacje: okno relacji snaponly -- naglowek 'co obejmuje', Cel 'ten sam dataset (migawki, bez kopii)', nie '?'"
else
    bad "relacje: okno snaponly -- co obejmuje / Cel" "$SOE"
fi
SOL="$(mktemp)"
"$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen relacje --width 120 --height 34 --keys enter,e,p --exec-log "$SOL" >/dev/null 2>&1
if grep -Eq "zfs-backup.sh'? edit-relation som --ask\$" "$SOL" 2>/dev/null && ! grep -q 'restore' "$SOL"; then
    ok "relacje: 'e' na relacji snaponly otwiera to samo okno zmiany (edit-relation --ask); 'p' nic nie uruchamia"
else
    bad "relacje: e/p na snaponly" "$(cat "$SOL")"
fi
# F2 Przebiegi: dwa zadania snaponly (hourly :39 i daily 01:49) to wiersze 'migawka hourly' i
# 'migawka daily' -- rodzina (dawny Prefiks) jest w nazwie szczebla w kolumnie Co; werdykt
# 'aktualne' jest na F3 (test 'relacje: dataset snaponly' wyzej). Wysokosc 400: dzienne
# zadanie biegnie dopiero jutro, wiec stoi na koncu osi czasu.
SO2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen zadania --width 200 --height 400 2>&1)"
if hasE "$SO2" "^║ $KD +som +migawka +hourly: [^ ]+ +nadchodzący" && hasE "$SO2" "^║ $KD +som +migawka +daily: [^ ]+ +nadchodzący"; then
    ok "zadania: zadania snaponly to 'migawka' z wlasnym szczeblem (hourly, daily) w kolumnie Co"
else
    bad "zadania: zadania snaponly" "$(printf '%s\n' "$SO2" | grep -E 'som')"
fi
rm -rf "$SOD" "$SOL"

# ============================================================================
# NOSNIKI
# ============================================================================
N="$(screen nosniki)"
# X11 (2026-10-12): kolumna Rodzaj po nazwie; sciezka sejf-b obcina sie wczesniej.
# U99: kolumny Replika | Typ | Wykonana | Ostatni bieg | Harmonogram; Typ: nosnik staly = wewnętrzny, wymienny
# poza maszyna = odłączony (stan "W SEJFIE" zostaje w panelu)
# Piec kolumn (Ostatni bieg, 2026-10-28): przy 80 znakach Harmonogram ustepuje (jest w panelu),
# wiec wiersze czytane przy 120.
NW="$(screen nosniki "" --width 120)"
if hasE "$NW" '^║ sejf-a +odłączony +brak +- +co dobę 02:30 +║' && hasE "$NW" '^║ sejf-b +wewnętrzny +brak +- +po podłączen'; then
    ok "nosniki: wiersz = replika, Typ nosnika slowem (U99), kiedy ostatnia aktualna kopia (Wykonana), harmonogram slowami (U21)"
else
    bad "nosniki: wiersze" "$NW"
fi
# Ostatni bieg (przejscie GUI pve10, 2026-10-28): calapula padla 4/4 rc=1, a lista mowila
# tylko "Wykonana 22.10". Kolumna niesie wynik i czas ostatniego biegu z job-stats.
NF="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" ${ALL%--stats*} --stats "$FIX/stats-replica-fail.json" --screen nosniki --width 160 --height 40 2>&1)"
if hasE "$NF" '^║ sejf-a +odłączony +brak +BŁĄD rc=1 11\.09 22:02 +co dobę' && hasE "$NF" '^║ sejf-b +wewnętrzny +brak +- +po podłączen'; then
    ok "nosniki: kolumna Ostatni bieg -- nieudany bieg repliki widac na liscie (BŁĄD rc=1 + czas)"
else
    bad "nosniki: Ostatni bieg" "$NF"
fi
# KONTROLA CZYTELNIKA: sejf-b nie ma linii `media` (--fixed). Stary list-replicas
# zwracal media="yes", recursive="latest" -- pola przesuniete o jedno przez
# IFS=tab. Fikstura pochodzi z NAPRAWIONEGO czytelnika i ten ekran to przypina.
NB="$(screen nosniki down --width 160)"
# U130 (2026-10-29): zrodlo -> cel, rekursja i historia stoja w prawym panelu repliki (grupa
# Co); dolna zakladka to jej przebiegi w ukladzie F2.
NBT="$(screen nosniki down,tab --width 160)"
if hasE "$NB" 'Źródło → cel +[^ ]+ → ' && hasE "$NB" 'Z dziećmi +tak' && hasE "$NB" 'Historia +latest' \
   && has "$NBT" 'sejf-b: [Przebiegi]' && hasE "$NBT" 'Kiedy +Wynik +Czas +Dane'; then
    ok "nosniki: replika --fixed ma rekursje i historie na SWOICH miejscach w prawym panelu (kontrola przesuniecia pol list-replicas); dol: [Przebiegi] Kiedy/Wynik/Czas/Dane"
else
    bad "nosniki: pola repliki --fixed" "$NB" "$NBT"
fi
if hasE "$NB" 'Nośnik +W SEJFIE -- nośnika nie ma w maszynie'; then
    ok "nosniki: stan nosnika ma jedno zdanie wyjasnienia"
else
    bad "nosniki: wyjasnienie stanu" "$NB"
fi
NE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --screen nosniki 2>&1)"
if has "$NE" 'Brak sekcji [replica:]' && has "$NE" 'NIE TEN DYSK' && has "$NE" 'add-replica NAZWA'; then
    ok "nosniki: bez replik -- powiedziane, ze to brak konfiguracji, z legenda czterech stanow i komenda"
else
    bad "nosniki: pusty" "$NE"
fi
# REPLIKI NA F2 I ICH BIEGI (2026-10-08): list-jobs replik nie zna, wiec F2 ich nie
# pokazywal, a job-stats liczyl ich biegi, ktorych zaden ekran nie wyswietlal.
RST="$(mktemp)"
"$PY" - "$P10/job-stats.json" "$RST" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d.setdefault("jobs", []).append({"label": "replica copy (sejf-a)", "runs": 4, "failures": 1, "avg_s": 3,
                                 "max_s": 7, "total_s": 12, "last_s": 2, "last_rc": 1, "last_at": "2026-09-08 02:30"})
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
RALL="--status $P10/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor.json --replicas $P10/replicas.json --stats $RST"
# F2 Przebiegi: replika z cronem to wiersz z terminem; replika 'po podłączeniu' nie ma terminu --
# Kiedy '-', na koncu osi czasu, a panel mowi 'bez terminu' (nie wymyslona godzina). Wysokosc 400:
# wiersz bez terminu jest ostatni.
Z2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $RALL --screen zadania --width 200 --height 400 2>&1)"
Z2K="$(zkeys '^║ - +sejf-b +replika ' $RALL)"
Z2B="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $RALL --screen zadania --keys "$Z2K" --width 200 --height 60 2>&1)"
if hasE "$Z2" "^║ $KD +sejf-a +replika +nadchodzący" && hasE "$Z2" '^║ - +sejf-b +replika +nadchodzący' && hasE "$Z2B" 'Kiedy +bez terminu'; then
    ok "zadania: repliki sa wierszami F2 (zadanie 'replika'); 'po podłączeniu' bez godziny -- Kiedy '-', w panelu 'bez terminu'"
else
    bad "zadania: wiersze replik" "$(printf '%s' "$Z2" | grep -E 'sejf|replika')" "$(printf '%s' "$Z2B" | grep -E 'Kiedy')"
fi
N2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $RALL --screen nosniki --width 200 --height 60 2>&1)"
if hasE "$N2" 'Ostatni bieg +2026-09-08 02:30   BŁĄD \(rc=1\)' && hasE "$N2" 'Wywołania +4, błędów 1' && hasE "$N2" 'Czas +ostatni 2s'; then
    ok "nosniki: panel repliki pokazuje ostatni bieg (kiedy, rc), czas i wywolania/bledy z job-stats"
else
    bad "nosniki: biegi repliki" "$(printf '%s' "$N2" | grep -E 'Ostatni|Wywołania|Czas')"
fi
rm -f "$RST"
# WERDYKT REPLIKI Z JEJ MONITORA (2026-10-08): linia bramy (`age`) daje monitor z
# etykieta = nazwa repliki i wzorcem "replica"; wiersz F2 bierze z niego werdykt.
RMN="$(mktemp)"
"$PY" - "$P10/monitor.json" "$RMN" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d.setdefault("monitors", []).append({"account": "root", "label": "sejf-a", "pattern": "replica", "datasets": ["bkp"],
    "warn": "2d", "crit": "4d", "verdict": "WARNING", "rc": 1, "parsed": True,
    "reason": "WARNING replica=sejf-a pool=bkp last_current=2026-09-06 02:30 age=3d0h (warn=2d crit=4d)"})
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
# F2 Przebiegi nie ma kolumny z werdyktem (lista mowi o biegu: Kiedy/Co/Wynik), a replika nie jest
# relacja, wiec werdyktu z monitora nie widac na zadnym ekranie -- reguly dopasowania monitora do
# repliki pilnujemy wiec tam, gdzie zyje: wiersze build_jobs (to z nich buduje sie F2) z tym samym
# UI, ktory czyta fikstury. Gdy werdykt wroci na ekran, ta asercja ma isc na ekran.
Z3="$("$PY" - "$TUI" "$REPO" "$NOW" "$P10/status.json" "$P10/list-jobs.json" "$RMN" "$P10/replicas.json" <<'PYEOF'
import importlib.util, sys
s = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
files = {"status": sys.argv[4], "jobs": sys.argv[5], "monitors": sys.argv[6], "progress": None, "replicas": sys.argv[7],
         "stats": None, "config": None, "profiles": None, "offline": True, "datasets_local": None,
         "datasets_remote": None, "check_source": None, "host_ip": None}
ui = m.UI(sys.argv[2], files, m.Chars(False), int(sys.argv[3]), None)
for r in m.build_jobs(ui.data, int(sys.argv[3])):
    if r["kind"] == "replica":
        print("%s=%s" % (r["name"], r["vword"]))
PYEOF
)"
Z3="$(printf '%s\n' "$Z3" | tr -d '\r')"
if printf '%s\n' "$Z3" | grep -qx 'sejf-a=spóźnione' && printf '%s\n' "$Z3" | grep -qx 'sejf-b=bez monitora'; then
    ok "zadania: wiersz repliki bierze werdykt z JEJ monitora (sejf-a spóźniona), bez monitora zostaje 'bez monitora' (sejf-b) -- na poziomie build_jobs, F2 Przebiegi go nie pokazuje"
else
    bad "zadania: werdykt repliki z monitora" "$Z3"
fi
rm -f "$RMN"
# Start i powrot z okna sa dwuetapowe (2026-10-29): job-stats dochodzi drugim etapem i dokłada
# wykonane biegi NAD kursorem. Kursor ma zostac na tym samym biegu ("teraz"), nie na tym samym
# numerze wiersza (pve10: F2 po starcie stalo na 08:13 zamiast przy nadchodzacym biegu).
Z4="$("$PY" - "$TUI" "$REPO" "$NOW" "$P10/status.json" "$P10/list-jobs.json" "$P10/monitor.json" "$P10/job-stats.json" <<'PYEOF'
import importlib.util, json, sys
s = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
files = {"status": sys.argv[4], "jobs": sys.argv[5], "monitors": sys.argv[6], "progress": None, "replicas": None,
         "stats": None, "config": None, "profiles": None, "offline": True, "datasets_local": None,
         "datasets_remote": None, "check_source": None, "host_ip": None}
ui = m.UI(sys.argv[2], files, m.Chars(False), int(sys.argv[3]), None)
i0 = ui.cursor["zadania"]; r0 = ui.runrows[i0]
# drugi etap: job-stats z wykonanymi biegami kazdej etykiety (1 h i 2 h temu)
import time
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(t))
now = int(sys.argv[3]); st = json.load(open(sys.argv[7], encoding="utf-8"))
st["runs"] = [{"label": r["label"], "start": iso(now - 3600 * k - 40), "end": iso(now - 3600 * k - 30), "rc": 0}
              for r in ui.runrows if r.get("label") for k in (1, 2)]
ui.data.stats = st
ui.apply_data(ui.data, full=False)
i1 = ui.cursor["zadania"]; r1 = ui.runrows[i1]
print("moved=%s same=%s upcoming=%s" % (i1 != i0, (r1.get("label"), r1.get("at")) == (r0.get("label"), r0.get("at")),
                                         not r1.get("past")))
PYEOF
)"
Z4="$(printf '%s' "$Z4" | tr -d '\r')"
if has "$Z4" 'moved=True same=True upcoming=True'; then
    ok "przebiegi: gdy job-stats dochodzi drugim etapem, kursor zostaje na tym samym nadchodzacym biegu (numer wiersza sie zmienia)"
else
    bad "przebiegi: kursor po drugim etapie" "$Z4"
fi
# REPLIKI Z GUI (2026-10-07): Ins nowa i Enter+'e' zmiana oddaja terminal oknom
# add-replica --ask; Del i F7 przez okno potwierdzenia, jak pauza na F3.
# W15 (wlasciciel 2026-10-11) + X9 (2026-10-12): F7 na F2 = zaznaczone zadanie TERAZ, bez
# okna potwierdzenia (jak F7 na replice) -- od razu DOKLADNIE linia z crona (bez pola
# harmonogramu), wynik w oknie. Sortowanie przeszlo na F8.
: > "$XL"
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen zadania --keys F7 2>&1)"
if ! has "$A" 'Uruchomić teraz?' && has "$A" 'bieg teraz' \
   && grep -q "/bin/sh -c .*zfs-job.sh" "$XL" && ! grep -Eq "sh -c '?[0-9*/,-]+ [0-9*/,-]+ " "$XL"; then
    ok "zadania: F7 uruchamia zaznaczone zadanie od razu (bez 't'), linia z crona bez pola harmonogramu"
else
    bad "zadania: F7 uruchom teraz (X9)" "$(cat "$XL")" "$(printf '%s' "$A" | grep -E 'Uruchom|bieg teraz|F7|F8' | head -4)"
fi
# X14 -> F2 Przebiegi: strażnik bez zadania to wiersz tylko do czytania (nie bieg) -- F7 mowi
# 'brak zadań -- nie ma czego uruchomić'. Komunikat X14 ('ten wiersz nie ma linii w cronie ...')
# zostaje dla WIERSZA BIEGU zadania, ktorego linii nie ma w cronie (osierocony wpis): fikstura
# P10 z wyczyszczonymi cron_lines, wiersz 0 to nadchodzacy bieg zadania. Listwa F2: F7 Uruchom
# teraz, F8 Schowaj wykonane, F9 Grupuj po relacji (zadnego 'Sortuj').
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/monitor-orphan.json" --screen zadania --keys F7 --width 200 2>&1)"
NCJ="$(mktemp)"
"$PY" - "$P10/list-jobs.json" "$NCJ" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for x in d["jobs"]:
    x["cron_lines"] = []
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
A2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$NCJ" --screen zadania --keys F7 --width 200 2>&1)"
rm -f "$NCJ"
if has "$A" 'brak zadań -- nie ma czego uruchomić' && ! has "$A" 'ten bieg już był' \
   && has "$A2" 'strażnik albo replika, bez harmonogramu, lub osierocony wpis' && has "$A" 'F7 Uruchom teraz F8 Schowaj wykonane F9 Grupuj po relacji' && ! has "$A" 'Sortuj'; then
    ok "zadania: X14 -- F7 na strażniku bez zadania: 'brak zadań'; na biegu bez linii w cronie: komunikat nazywa strażnika, replikę bez harmonogramu i osierocony wpis; listwa F7 Uruchom teraz / F8 Schowaj wykonane / F9 Grupuj po relacji"
else
    bad "zadania: X14 komunikat" "$(printf '%s' "$A" | tail -4)" "$(printf '%s' "$A2" | tail -4)"
fi
# X11 (wlasciciel 2026-10-12): replika na liscie i w panelu mowi, CO TRAFIA NA DYSK --
# kolumna Rodzaj (historia / migawki xN), panel: Rodzaj, Na dysku (z przykladem), Szyfrowane.
# U93: "zdjecia" -> migawki; U99: kolumny listy Replika | Typ | Wykonana | Harmonogram.
F6R="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen nosniki --width 200 --height 40 2>&1)"
if hasE "$F6R" '║ Replika +Typ +Wykonana +Ostatni bieg +Harmonogram' && hasE "$F6R" 'Rodzaj +własne migawki -- replika' \
   && hasE "$F6R" 'Na dysku +2 ostatnie migawki = ok\. 2 dni wstecz' && hasE "$F6R" 'Szyfrowane +nie' && ! has "$F6R" 'zdjęc'; then
    ok "nosniki: X11 -- panel: Rodzaj, Na dysku z przykladem, Szyfrowane (U21: rodzaj w panelu, nie w liscie)"
else
    bad "nosniki: X11 Rodzaj repliki" "$(printf '%s' "$F6R" | sed -n 2,12p)"
fi
# W19b (wlasciciel 2026-10-11/13): zaszyfrowany nosnik -- panel mowi "nośnik zaszyfrowany
# (klucz: F8)", F8 pokazuje klucz z pliku; replika bez klucza: komunikat, bez okna.
RMK="$(mktemp)"; KF="$(mktemp)"; printf 'ab12cd34ef56' > "$KF"
"$PY" - "$P10/replicas.json" "$RMK" "$KF" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["replicas"][0]["media_key"] = sys.argv[3]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
K1="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RMK" --screen nosniki --width 200 --height 40 2>&1)"
K2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RMK" --screen nosniki --keys F8 --width 200 --height 40 2>&1)"
K3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RMK" --screen nosniki --keys down,F8 --width 200 --height 40 2>&1)"
if hasE "$K1" 'Szyfrowane +nośnik zaszyfrowany \(klucz: F8\)' && has "$K1" 'F8 Klucz' && has "$K2" 'Klucz nośnika repliki sejf-a' && has "$K2" 'ab12cd34ef56' \
   && ! has "$K3" 'Klucz nośnika' && has "$K3" 'replika sejf-b nie ma zaszyfrowanego nośnika'; then
    ok "nosniki: W19b -- panel mowi o zaszyfrowanym nosniku, F8 pokazuje klucz z pliku; replika bez klucza dostaje komunikat"
else
    bad "nosniki: W19b klucz" "$(printf '%s' "$K1" | grep -E 'Szyfrowane|F8')" "$(printf '%s' "$K2" | grep -E 'Klucz|ab12' | head -2)" "$(printf '%s' "$K3" | tail -3)"
fi
rm -f "$RMK" "$KF"
# X23 (wlasciciel 2026-10-14): F7 na wierszu REPLIKI na F2 uruchamia replike (jak F7 na F6),
# zamiast "nie ma linii w cronie" -- wiersz repliki powstaje z list-replicas, bez linii crona.
: > "$XL"
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/empty-mon.json" --replicas "$P10/replicas.json" --exec-log "$XL" --screen zadania --keys F7 --width 160 2>&1)"
if has "$A" 'Replika sejf-a -- biegnie teraz' && grep -q "run-replicas --name=sejf-a" "$XL" && ! has "$A" 'nie ma linii w cronie'; then
    ok "zadania: X23 -- F7 na wierszu repliki uruchamia run-replicas --name (jak F6)"
else
    bad "zadania: X23 F7 na replice" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
nact() {   # <keys> -> ekran F6; dziennik komend w $XL (wyzerowany)
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen nosniki --keys "$1" 2>&1
}
A="$(nact ins)"
if grep -Eq "zfs-backup.sh'? add-replica --ask\$" "$XL"; then
    ok "nosniki: Ins oddaje terminal oknom nowej repliki (add-replica --ask)"
else
    bad "nosniki: Ins -> add-replica --ask" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(nact enter,e)"
if grep -Eq "zfs-backup.sh'? add-replica sejf-a --ask\$" "$XL"; then
    ok "nosniki: Enter i 'e' w oknie repliki oddaje terminal oknom ZMIANY tej repliki (add-replica NAZWA --ask)"
else
    bad "nosniki: e -> add-replica NAZWA --ask" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(nact enter)"
if has "$A" 'e zmienia replikę'; then
    ok "nosniki: ...okno repliki mowi o tym w stopce"
else
    bad "nosniki: stopka okna repliki" "$(printf '%s' "$A" | tail -3)"
fi
A="$(nact down,del)"
if grep -Eq "zfs-backup.sh'? remove-replica sejf-b --ask\$" "$XL"; then
    ok "nosniki: Del oddaje terminal oknom usuwania repliki POD KURSOREM (remove-replica NAZWA --ask: kopia na nosniku tylko na zyczenie)"
else
    bad "nosniki: Del -> remove-replica" "$(cat "$XL")" "$A"
fi
# Uwaga 17 (2026-10-08): dysk w slocie mowi, czy kopia na nim jest aktualna.
RSL="$(mktemp)"
"$PY" - "$P10/replicas.json" "$RSL" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
d["replicas"][0].update({"present": "available", "last_current": "2026-10-08 20:46"})
d["replicas"][1].update({"present": "available", "last_current": ""})
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
S1="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RSL" --screen nosniki --width 200 --height 50 2>&1)"
S2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RSL" --screen nosniki --keys down --width 200 --height 50 2>&1)"
if has "$S1" 'Podłączony -- kopia aktualna z 2026-10-08 20:46' && has "$S2" 'Podłączony -- brak kopii' && has "$S1" 'Wykonana'; then
    ok "nosniki: dysk w slocie mowi, czy kopia na nim jest aktualna (z czasem) albo ze kopii brak; kolumna 'Wykonana'"
else
    bad "nosniki: w slocie + kopia" "$(printf '%s\n' "$S1" | grep -E 'Podłączony|Kopia')" "$(printf '%s\n' "$S2" | grep -E 'Podłączony')"
fi
rm -f "$RSL"
# U99: kolumna Typ w liscie F6 -- nosnik staly: wewnętrzny; wymienny: podłączony (w maszynie: here
# i available), odłączony (away); inny stan zostaje slowem bramy (NIE TEN DYSK). Wiersze wprost
# z pieciu replik o roznych (media, present).
RTY="$(mktemp)"
"$PY" - "$P10/replicas.json" "$RTY" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
base = d["replicas"][0]
def mk(name, media, present):
    r = dict(base)
    r.update({"name": name, "media": media, "present": present, "last_current": ""})
    return r
d["replicas"] = [mk("r-fixed", "fixed", "away"), mk("r-here", "usbA", "here"), mk("r-avail", "usbA", "available"),
                 mk("r-away", "usbA", "away"), mk("r-wrong", "usbA", "wrong_medium")]
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"))
PYEOF
RTYS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --replicas "$RTY" --screen nosniki --width 200 --height 50 2>&1)"
if hasE "$RTYS" '^║ r-fixed +wewnętrzny ' && hasE "$RTYS" '^║ r-here +podłączony ' && hasE "$RTYS" '^║ r-avail +podłączony ' \
   && hasE "$RTYS" '^║ r-away +odłączony ' && hasE "$RTYS" '^║ r-wrong +NIE TEN DYSK '; then
    ok "nosniki U99: Typ -- staly 'wewnętrzny' (mimo present=away), here i available 'podłączony', away 'odłączony', zly dysk slowem bramy"
else
    bad "nosniki U99: Typ nosnika" "$(printf '%s\n' "$RTYS" | grep -E '^║ (Replika|r-)')"
fi
rm -f "$RTY"
A="$(nact F7)"
# Uwaga 18 (2026-10-08): F7 uruchamia ZAZNACZONA replike od razu -- bez okna "t".
if ! has "$A" 'POTWIERDZENIE' && grep -Eq "zfs-backup.sh'? run-replicas '?--name=sejf-a'?\$" "$XL"; then
    ok "nosniki: F7 uruchamia od razu replike POD KURSOREM (run-replicas --name=sejf-a), bez pytania"
else
    bad "nosniki: F7 -> run-replicas --name" "$(cat "$XL")" "$A"
fi
nact e >/dev/null
if [ ! -s "$XL" ]; then
    ok "nosniki: ...bez okna 'e' jest tekstem linii polecen i niczego nie uruchamia"
else
    bad "nosniki: 'e' bez okna uruchomil czasownik" "$(cat "$XL")"
fi

# ============================================================================
# LINIA POLECEN (wlasciciel 2026-09-11: "chcemy moc w kazdej chwili pisac
# komendy z palca"). Nad listwa klawiszy, na KAZDYM ekranie; styl mc.
# ============================================================================
cl_ok=1
for sc in zadania relacje nosniki; do
    out="$(screen "$sc" "")"
    printf '%s\n' "$out" | tail -2 | head -1 | grep -qE '^[^ ]+@pve10:zfs-snapshot-all\$ _ *$' || { cl_ok=0; echo "  $sc: brak linii polecen"; }
done
if [ "$cl_ok" -eq 1 ]; then
    ok "linia: kazdy ekran ma linie polecen user@host:repo\$ tuz nad listwa klawiszy"
else
    bad "linia: obecnosc na ekranach"
fi
XL="$(mktemp)"
C="$(: > "$XL"; screen relacje "text:ls -la,bs" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ ls -l_ *$' && [ ! -s "$XL" ]; then
    ok "linia: pisanie i Backspace edytuja linie; samo pisanie NICZEGO nie uruchamia"
else
    bad "linia: edycja" "$C"
fi
C="$(: > "$XL"; screen relacje "text:ls -l,enter" --exec-log "$XL")"
if [ "$(cat "$XL")" = "ls -l" ] && has "$C" '[tryb testowy] nie uruchomiono, zapisano do dziennika: ls -l'; then
    ok "linia: Enter wykonuje DOKLADNIE wpisana linie (atrapa: dziennik) i czysci linie"
else
    bad "linia: Enter" "$(cat "$XL")" "$C"
fi
C="$(: > "$XL"; screen relacje "text:ls -l,enter,text:x,up" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ ls -l_ *$'; then
    ok "linia: strzalka w gore przy niepustej linii = historia"
else
    bad "linia: historia" "$C"
fi
C="$(: > "$XL"; screen relacje "text:abc,esc" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ _ *$' && [ ! -s "$XL" ]; then
    ok "linia: Esc czysci linie"
else
    bad "linia: Esc" "$C"
fi
C="$(: > "$XL"; screen relacje "text:abc,down,down" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ abc_ *$' && has "$C" 'duplikat -- relacja'; then
    ok "linia: z tekstem w linii strzalki NIE ruszaja listy (kursor zostaje na pierwszym wierszu)"
else
    bad "linia: strzalki przy tekscie" "$C"
fi
# Tab w potwierdzeniu (właściciel 2026-10-18; wcześniej litera 'e'): komenda akcji
# laduje w linii do poprawki, nic nie rusza. 'e' nic juz tu nie robi.
C="$(: > "$XL"; screen relacje "down,F8,tab" --exec-log "$XL")"
if has "$C" "pause-client lab-ct201 '--reason=z TUI" && ! has "$C" 'POTWIERDZENIE' && [ ! -s "$XL" ] && has "$C" 'komenda w linii poleceń -- popraw i Enter'; then
    ok "linia: Tab w potwierdzeniu wrzuca pokazana komende do linii polecen (podglad + edycja), dziennik pusty"
else
    bad "linia: Tab w potwierdzeniu" "$C" "$(cat "$XL")"
fi
C="$(: > "$XL"; screen relacje "down,F8,e" --exec-log "$XL")"
if ! has "$C" 'POTWIERDZENIE' && ! hasE "$C" 'pause-client lab-ct201.*_ *$' && [ ! -s "$XL" ]; then
    ok "linia: 'e' w potwierdzeniu to juz zaden skrot -- jak kazdy inny klawisz wraca, nic nie wrzuca do linii i nic nie uruchamia"
else
    bad "linia: e w potwierdzeniu" "$C" "$(cat "$XL")"
fi
C="$(: > "$XL"; screen relacje "down,F8" --exec-log "$XL")"
# POD OKNEM WIDAC LINIE POLECEN z komenda zlozona przez okno, i pasek F.
# (Dluga komenda jest ucieta od poczatku -- widac jej koniec, jak przy pisaniu.)
if printf '%s\n' "$C" | tail -2 | head -1 | grep -q "pause-client lab-ct201 '--reason=z TUI" \
   && printf '%s\n' "$C" | tail -1 | grep -q '12Wyj\|F12' && has "$C" '═ t wykonuje   ' && has "$C" 'Tab do linii poleceń   Esc wraca'; then
    ok "linia: pod oknem potwierdzenia zostaje linia polecen z jego komenda i pasek klawiszy; stopka 't wykonaj   Tab do linii poleceń'"
else
    bad "linia: linia polecen pod oknem" "$(printf '%s\n' "$C" | tail -3)"
fi
C="$(: > "$XL"; screen relacje "down,F8,tab,bs,bs,bs,bs,bs,bs,enter" --exec-log "$XL")"
if grep -q "pause-client lab-ct201 '--reason=z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ]; then
    ok "linia: ...poprawiona (6 x Backspace) i Enter wykonuje TO, co w linii"
else
    bad "linia: Tab + edycja + Enter" "$(cat "$XL")" "$C"
fi
# TAB = kolejny obiekt: lista -> linia polecen -> lista; w linii strzalka w gore to
# historia takze przy pustej linii, Esc wraca do listy.
C="$(: > "$XL"; screen zadania "text:ls -l,enter,tab,up" --exec-log "$XL")"
C="$(: > "$XL"; screen zadania "text:ls -l,enter,tab,tab,up" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ ls -l_ *$'; then
    ok "linia: Tab (lista -> przebiegi -> linia) przenosi do linii polecen, strzalka w gore przy pustej linii = historia"
else
    bad "linia: Tab + historia" "$C"
fi
C1="$(screen zadania "down" | sed 1d)"; C2="$(screen zadania "tab,down" | sed 1d)"; C3="$(screen zadania "tab,tab,down" | sed 1d)"; C4="$(screen zadania "tab,esc,down" | sed 1d)"
C1="$(screen zadania "down" | sed 1d)"; C2="$(screen zadania "tab,tab,down" | sed 1d)"; C3="$(screen zadania "tab,tab,tab,down" | sed 1d)"; C4="$(screen zadania "tab,esc,down" | sed 1d)"
if [ "$C2" != "$C1" ] && [ "$C3" = "$C1" ] && [ "$C4" = "$C1" ]; then
    ok "linia: w linii polecen strzalki nie ruszaja listy; Tab (lista -> przebiegi -> linia -> lista) albo Esc z dolnego panelu wraca do listy"
else
    bad "linia: fokus Tab" "$(printf '%s\n' "$C2" | head -8)"
fi
C1="$(screen relacje "down" | sed 1d)"; C2="$(screen relacje "tab,tab,tab,down" | sed 1d)"
if [ "$C2" = "$C1" ]; then
    ok "linia: na F3 Tab krazy lista -> pary -> linia -> lista"
else
    bad "linia: Tab na F3" "$(printf '%s\n' "$C2" | head -8)"
fi
C="$(: > "$XL"; screen relacje "q,text:uit" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ quit_ *$' && has "$C" 'Relacje na kolektorze'; then
    ok "linia: litera 'q' na ekranie to TEKST, nie wyjscie (zmierzone na pve9: 'echo' dawalo 'cho', gdy 'e' bylo skrotem)"
else
    bad "linia: q jest tekstem" "$C"
fi
C="$(: > "$XL"; screen relacje "text:zfs list,F12" --exec-log "$XL")"
if [ ! -s "$XL" ]; then
    ok "linia: F12 wychodzi takze z tekstem w linii, nic nie uruchamiajac"
else
    bad "linia: F12" "$(cat "$XL")"
fi
C="$(: > "$XL"; screen relacje "F10" --exec-log "$XL")"
if grep -Eq "zfs-backup.sh'? settings --ask\$" "$XL" && has "$C" '10Ust'; then
    ok "F10: Ustawienia -- oddaje terminal oknu ustawien hosta (settings --ask); na pasku 'F10 Ustawienia' (wlasciciel 2026-10-19)"
else
    bad "F10: Ustawienia" "$(cat "$XL")" "$(printf '%s' "$C" | tail -2)"
fi
rm -f "$XL"

# ============================================================================
# KONTRAKT WYGLADU: 80 to przypadek projektowy, 120 i 200 wykorzystuja miejsce
# ============================================================================
widths_ok=1
for w in 80 120 200; do
    for sc in zadania relacje nosniki; do
        for keys in "" "enter" "F1"; do
            out="$(screen "$sc" "$keys" --width "$w" --height 24)"
            n="$(printf '%s\n' "$out" | "$PY" -c "import sys; ls=sys.stdin.read().split('\n')[:-1]; print(sum(1 for l in ls if len(l)!=$w), len(ls))")"
            case "$n" in "0 24") ;; *) widths_ok=0; echo "  $sc w=$w keys=$keys -> (zle linie, wszystkie): $n" ;; esac
        done
    done
done
if [ "$widths_ok" -eq 1 ]; then
    ok "wyglad: kazda linia kazdego ekranu i okna ma DOKLADNIE szerokosc terminala (80/120/200), 24 wiersze"
else
    bad "wyglad: szerokosci linii"
fi
if [ "$(printf '%s\n' "$S120" | grep -c '║.*│')" -gt 5 ] && [ "$(printf '%s\n' "$S" | grep -c '║.*│')" -gt 5 ] \
        && has "$S" '╔═ duplikat (wg rekordu, nie crona): [Datasety]' && has "$S120" '╔═ duplikat (wg rekordu, nie crona): [Datasety]'; then
    ok "wyglad: F3 w trzech panelach przy 80 i 120 -- lista, panel obok, zakladki na dole"
else
    bad "wyglad: trzy panele" "$S" "$S120"
fi
# Terminal bez UTF-8: ramki +-|= i slowa bez ogonkow. Zero bajtow spoza ASCII.
ascii_ok=1
for sc in zadania relacje nosniki; do
    for keys in "" "enter" "F1"; do
        out="$("$PY" "$TUI" --render-once --offline --ascii --now "$NOW" $ALL --screen "$sc" --keys "$keys" 2>&1)"
        if [ "$(printf '%s' "$out" | LC_ALL=C grep -c '[^ -~]')" -ne 0 ]; then ascii_ok=0; echo "  $sc keys=$keys ma bajty spoza ASCII"; fi
        has "$out" '+=' || { ascii_ok=0; echo "  $sc keys=$keys bez ramki ASCII"; }
    done
done
if [ "$ascii_ok" -eq 1 ]; then
    ok "wyglad: tryb ASCII -- ramki +-|=, slowa bez ogonkow, zero bajtow spoza ASCII na kazdym ekranie i oknie"
else
    bad "wyglad: tryb ASCII"
fi
A="$("$PY" "$TUI" --render-once --offline --ascii --now "$NOW" $ALL --screen relacje 2>&1)"
A="$("$PY" "$TUI" --render-once --offline --ascii --now "$NOW" $ALL --screen relacje --width 120 2>&1)"
if hasE "$A" '^\| lab-ct201 +backup +pve9 > pve10 +dzia(ł|l)a +aktualne +\|' && has "$A" 'duplikat (wg rekordu, nie crona): [Datasety]' && has "$A" 'pve9:hdd/lab/vm-101 -> hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "wyglad: w ASCII te same slowa (aktualne, Zrodla) -- werdykt niesie slowo, nie tylko kolor"
else
    bad "wyglad: slowa w ASCII" "$A"
fi
HLP="$(screen relacje F1 --height 100 --width 120)"   # tresc slownika; zawijanie na 80 ma osobny test (kampania 3)
if has "$HLP" '╔═ Pomoc ═' && has "$HLP" 'bez monitora   NIKT nie pyta' && has "$HLP" 'NAJPIERW komenda bash'; then
    ok "pomoc: F1 otwiera pomoc ze slownikiem kolumny Kopie"
else
    bad "pomoc: F1" "$HLP"
fi
if has "$S" '1Pomoc2Przeb3Rel4Kopie5Szabl6Repl7Uruchom8Pauza9Plik10Ust12Wyjdź' && ! has "$(printf '%s\n' "$S" | tail -1)" '11'; then
    ok "wyglad: przy 80 kolumnach pasek miesci WSZYSTKIE klawisze F, z F12 i bez F11 (zapis skrocony, cyfra = F; najciasniej Przeb/Kopie/Szabl/Wyjdz)"
else
    bad "wyglad: listwa F" "$S"
fi
# BEZ DUBLI (wlasciciel 2026-10-09, uwaga 4: "Klawisze F sa podublowane z paska i wewnatrz
# okna"; "trzeba to zrobic poprawnie bez dubli"). Kazdy ekran, kazda szerokosc: klawisz F
# wystepuje TYLKO w ostatniej linii (pasek), a kazda akcja okna jest na pasku dokladnie raz.
NODUP=""
for _sc in zadania relacje szablony nosniki; do
    for _w in 80 120 200; do
        _o="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --screen "$_sc" --width "$_w" --height 30 2>&1)"
        _body="$(printf '%s\n' "$_o" | sed '$d')"; _bar="$(printf '%s\n' "$_o" | tail -1)"
        printf '%s' "$_body" | grep -qE '(^|[^A-Za-z0-9])F([1-9]|1[0-2])([^0-9]|$)' && NODUP="$NODUP $_sc/$_w:F-w-oknie"
        case "$_sc" in
            # F2 Przebiegi: F8 'Schowaj wykonane'/'Pokaż wykonane' (krotko 'Wykonane'), F9 'Grupuj po relacji'
            # (krotko 'Grupuj') -- wspolny rdzen 'ykonane' i 'Grupuj' jest na pasku raz przy kazdej szerokosci.
            zadania) _acts="Uruchom ykonane Grupuj" ;; relacje) _acts="Uruchom Pauza" ;;
            nosniki) _acts="Uruchom" ;; *) _acts="" ;;
        esac
        # Przeb/Kopie/Szabl/Wyj: pelne slowo albo najciasniejszy skrot (80 kolumn); bez Historii i Odzysku (F11 wolny).
        for _a in Pomoc Przeb Rel Kopie Szabl Repl Ust Wyj $_acts; do
            [ "$(printf '%s' "$_bar" | grep -o "$_a" | wc -l)" -eq 1 ] || NODUP="$NODUP $_sc/$_w:$_a"
        done
    done
done
if [ -z "$NODUP" ]; then
    ok "klawisze: na kazdym ekranie (80/120/200 kolumn) F tylko na pasku, kazda akcja na pasku dokladnie raz"
else
    bad "klawisze: dubel albo brak na pasku" "$NODUP"
fi
# Aktywne okno: kolor (marks), bez [nawiasow] -- na kazdej szerokosci zaznaczony jest ten ekran.
MKOUT="$("$PY" - "$TUI" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("zt", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
out = []
for w in (80, 120, 200):
    line, marks = m.key_bar_parts("odzysk", w, m.screen_actions("odzysk"))
    act = [line[a:b] for a, b, k in marks if k == "active"]
    out.append("%s:%s" % (w, "|".join(act)))
print(" ".join(out))
PYEOF
)"
# F4 ma od 2026-10-29 trzy akcje (F7, F8 grupy, F9), jak F2: przy 120 pasek zwija podpisy.
if [ "$MKOUT" = "80:4Kopie 120:4Kopie 200:F4 Kopie" ]; then
    ok "klawisze: aktywne okno zaznaczone na pasku kolorem (marks), bez nawiasow"
else
    bad "klawisze: zaznaczenie aktywnego okna" "got=$MKOUT"
fi
# Zadnego slownika kodow wyjscia w kolumnie Kopie: to slowa wlasciciela.
if ! hasE "$S" 'KRYTYCZNY|NIEZNANY|najgorszy werdykt'; then
    ok "wyglad: kolumna Kopie mowi slowami wlasciciela, nie etykietami kontraktu"
else
    bad "wyglad: slownik kontraktu na ekranie" "$S"
fi

# ============================================================================
# KONTROLE UJEMNE: zepsute zrodlo to komunikat, nie pusta tabela
# ============================================================================
BROKEN="$REPO/test/tui/fixtures/.broken.json"
printf '{"relations": [ this is not json' > "$BROKEN"
X="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$BROKEN" --jobs "$P10/list-jobs.json" --screen relacje 2>&1)"
if has "$X" 'błąd źródła: status --json nie odpowiedział poprawnym JSON-em' && ! has "$X" 'Zero relacji'; then
    ok "ujemna: zepsuty status --json -> 'blad zrodla' na ekranie Relacje, NIE 'zero relacji'"
else
    bad "ujemna: zepsuty status" "$X"
fi
if has "$X" '! bez odpowiedzi: 1'; then
    ok "ujemna: ...i pasek tytulu liczy zrodla bez odpowiedzi"
else
    bad "ujemna: licznik w pasku" "$X"
fi
XT="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$BROKEN" --screen zadania 2>&1)"
XN="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --replicas "$BROKEN" --screen nosniki 2>&1)"
if has "$XT" 'błąd źródła: list-jobs --json' && has "$XN" 'błąd źródła: list-replicas --json'; then
    ok "ujemna: kazdy z pozostalych ekranow nazywa SWOJE zepsute zrodlo (F4 Historia i F5/monitor zniesione razem z ekranami)"
else
    bad "ujemna: zepsute zrodla na pozostalych ekranach" "$XT" "$XN"
fi
XZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$FIX/nie-ma-takiego-pliku.json" --screen relacje 2>&1)"
if has "$XZ" 'błąd źródła' && ! has "$XZ" 'Traceback'; then
    ok "ujemna: brakujacy plik zrodla to tez 'blad zrodla', nie traceback"
else
    bad "ujemna: brak pliku" "$XZ"
fi
rm -f "$BROKEN"
# Bez terminala i bez --render-once: odmowa z instrukcja, rc=2, zero rysowania.
NT="$("$PY" "$TUI" --offline </dev/null 2>&1 | cat)"; rc=${PIPESTATUS[0]}
if has "$NT" 'to nie jest terminal -- uzyj --render-once'; then
    ok "ujemna: bez tty program odmawia i mowi, jak zobaczyc ekran"
else
    bad "ujemna: bez tty" "$NT"
fi

# ============================================================================
# KURSOR PO POWROCIE Z KREATORA (Ins na F3)
#
# Lista relacji jest posortowana, a kursor to INDEKS. Po zalozeniu relacji
# `refresh()` tylko przycinal indeks do dlugosci listy, wiec kursor zostawal na
# starym miejscu i wskazywal cudzy wiersz -- panel obok pokazywal szczegoly nie
# tej relacji, ktora operator wlasnie zalozyl. Sprawdzane na dwoch STANACH
# danych (przed i po), przez wywolanie tej samej metody, ktorej uzywa petla.
CUR="$("$PY" - "$TUI" <<'EOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tui", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class U(object):    # tylko to, czego dotyka cursor_to_new
    rel_names = m.UI.rel_names.__func__ if hasattr(m.UI.rel_names, "__func__") else m.UI.rel_names
    cursor_to_new = m.UI.cursor_to_new.__func__ if hasattr(m.UI.cursor_to_new, "__func__") else m.UI.cursor_to_new
    def __init__(self, names):
        self.rows = [{"name": n, "rel": {"name": n}} for n in names]
        self.cursor = {"relacje": 0}; self.screen = "zadania"; self.focus = "pairs"
u = U(["alfa", "beta", "delta"]); before = u.rel_names()
u2 = U(["alfa", "beta", "ceta", "delta"]); u2.cursor["relacje"] = 0
print("moved %s idx %d screen %s focus %s" % (u2.cursor_to_new(before), u2.cursor["relacje"], u2.screen, u2.focus))
u3 = U(["alfa", "beta", "delta"]); u3.cursor["relacje"] = 2
print("same %s idx %d" % (u3.cursor_to_new(before), u3.cursor["relacje"]))
u4 = U(["alfa", "beta", "ceta", "delta", "eta"]); u4.cursor["relacje"] = 1
print("two %s idx %d" % (u4.cursor_to_new(before), u4.cursor["relacje"]))
u5 = U(["alfa", "beta"]); u5.cursor["relacje"] = 1
print("gone %s idx %d" % (u5.cursor_to_new(before), u5.cursor["relacje"]))
EOF
)"
if has "$CUR" 'moved True idx 2 screen relacje focus list'; then
    ok "kursor: po powrocie z kreatora kursor staje na relacji, ktora PRZYBYLA (nie na starym indeksie), a ekran wraca na liste F3"
else
    bad "kursor: nowa relacja" "$CUR"
fi
if has "$CUR" 'same False idx 2' && has "$CUR" 'two False idx 1' && has "$CUR" 'gone False idx 1'; then
    ok "kursor: gdy nic nie przybylo, przybyly dwie relacje albo lista sie SKROCILA -- kursor zostaje tam, gdzie byl (nie zgadujemy)"
else
    bad "kursor: przypadki bez jednoznacznej nowej relacji" "$CUR"
fi

# ============================================================================
# PARSER CRONA: nastepny bieg, semantyka vixie
# ============================================================================
CR="$("$PY" - "$TUI" "$NOW" <<'EOF'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("tui", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
now = int(sys.argv[2]); out = []
n = m.cron_next("30 * * * *", now); lt = time.localtime(n); out.append("hourly %d %d" % (lt.tm_min, 0 < n - now <= 3600))
n = m.cron_next("*/15 * * * *", now); out.append("step %d %d" % (time.localtime(n).tm_min % 15, 0 < n - now <= 900))
n = m.cron_next("0 4 * * 0", now); lt = time.localtime(n); out.append("sunday %d %d:%02d" % ((lt.tm_wday + 1) % 7, lt.tm_hour, lt.tm_min))
n = m.cron_next("15 2 1 * *", now); lt = time.localtime(n); out.append("monthly %d %d:%02d" % (lt.tm_mday, lt.tm_hour, lt.tm_min))
n = m.cron_next("5 3 1 * 3", now); lt = time.localtime(n); out.append("dom_or_dow %d" % int(lt.tm_mday == 1 or (lt.tm_wday + 1) % 7 == 3))
out.append("bad %s %s" % (m.cron_next("garbage", now), m.cron_next("61 * * * *", now)))
print("\n".join(out))
EOF
)"
if has "$CR" 'hourly 30 1' && has "$CR" 'step 0 1'; then
    ok "cron: '30 * * * *' i '*/15' daja nastepna minute w oknie jednej kadencji"
else
    bad "cron: proste harmonogramy" "$CR"
fi
if has "$CR" 'sunday 0 4:00' && has "$CR" 'monthly 1 2:15'; then
    ok "cron: dzien tygodnia (niedziela=0) i dzien miesiaca liczone poprawnie"
else
    bad "cron: dow/dom" "$CR"
fi
if has "$CR" 'dom_or_dow 1' && has "$CR" 'bad None None'; then
    ok "cron: dom i dow oba ograniczone = LUB (vixie); smieci i wartosci spoza zakresu daja None, nie wyjatek"
else
    bad "cron: vixie OR i wejscia bledne" "$CR"
fi

# ============================================================================
# new-relation: KREATOR NA WHIPTAILU, kroki 1-4 (2026-09-18)
#
# Wlasciciel 2026-09-16: formularze w whiptail, nie rysowane w curses. Tu sprawdzana
# jest LOGIKA ciagu okien: co kreator proponuje, w jakiej kolejnosci, co z tego
# sklada. Atrapa whiptaila ma ten sam kontrakt sterowania co prawdziwy: odpowiedz
# na stderr, rc 0 = OK, 1 = Wstecz/Nie, 255 = Esc; --infobox nie czeka na nic.
# WYGLAD (ramki, 80x25, polskie znaki) jest dowodzony jazda po pty z prawdziwym
# whiptailem na hoscie -- atrapa nie ma o nim nic do powiedzenia (R12).
# ============================================================================
NR="$(mktemp -d)"; mkdir -p "$NR/bin"
NRS="$REPO/tui/new-relation.sh"
cat > "$NR/bin/whiptail" <<'EOF'
#!/bin/bash
# argv w jednej linii dziennika; odpowiedzi kolejno z pliku: "rc<TAB>tekst" (| = nowa linia)
printf '%s\n' "$(printf '%s ~ ' "$@")" >> "${NR_DIR:?}/wt.log"
# --textbox pokazuje PLIK: jego tresc do dziennika, jak tekst --yesno (plan dluzszy niz ekran).
p=""; for a in "$@"; do [ "$p" = "--textbox" ] && cat "$a" >> "$NR_DIR/wt.log"; p="$a"; done
for a in "$@"; do [ "$a" = "--infobox" ] && exit 0; done
# Okno tekstu (--textbox) nie ma wyboru: prawdziwy whiptail konczy je Dalej (rc 0) -- nie
# zabiera odpowiedzi (kampania 2026-10-22: dlugi plan = tekst + krotkie pytanie).
for a in "$@"; do [ "$a" = "--textbox" ] && exit 0; done
n=$(cat "$NR_DIR/wt.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$NR_DIR/wt.n"
line=$(sed -n "${n}p" "$NR_DIR/answers")
# Koniec odpowiedzi: "Przerwać?" kreatora i repliki i "Porzucić zmiany?" kart zmiany dostają Przerwij/Porzuć (Esc = Zostań i test krążyłby
# bez końca); każde inne okno -- 255, jak Esc.
if [ -z "$line" ]; then
    echo "ATRAPA: brak odpowiedzi nr $n" >> "$NR_DIR/wt.log"
    for a in "$@"; do case "$a" in "Nowa relacja: przerwać?"|"Nowa replika: przerwać?"|"Porzucić zmiany?") exit 0 ;; esac; done
    exit 255
fi
rc="${line%%	*}"; out="${line#*	}"
# KONTRAKT PRAWDZIWEGO WHIPTAILA: z listy da sie wybrac TYLKO to, co na niej jest. Bez
# tego atrapa przyjela 'hdd/backups', gdy kreator oferowal 'hdd/backups<TAB>active'
# (wada znaleziona dopiero na pve10, 2026-09-20) -- odpowiedz omijala oferte.
kind=""; step=0; i=0; tags=()
for a in "$@"; do
    i=$((i+1))
    case "$a" in --menu) kind=menu; step=2; at=$i ;; --radiolist|--checklist) kind=list; step=3; at=$i ;; esac
done
if [ -n "$kind" ]; then
    j=$((at + 5)); while [ "$j" -le "$#" ]; do tags+=("${!j}"); j=$((j + step)); done
    # Oferta sama w sobie: znacznik z tabulatorem to sklejone pola (tak wygladal cel
    # 'hdd/backups<TAB>active'), a --default-item spoza listy to kursor nie tam, gdzie mysli kod.
    for t in "${tags[@]}"; do
        case "$t" in *"	"*) echo "ATRAPA: znacznik listy zawiera TAB (sklejone pola): '$t'" >> "$NR_DIR/wt.log"; echo "ATRAPA: TAB w znaczniku" >&2; exit 255 ;; esac
    done
    i=0; for a in "$@"; do
        i=$((i+1))
        if [ "$a" = "--default-item" ]; then
            k=$((i+1)); di="${!k}"; ok=0; for t in "${tags[@]}"; do [ "$t" = "$di" ] && ok=1; done
            [ "$ok" -eq 1 ] || { echo "ATRAPA: --default-item '$di' NIE MA na liscie: ${tags[*]}" >> "$NR_DIR/wt.log"; echo "ATRAPA: default-item spoza listy" >&2; exit 255; }
        fi
    done
fi
if [ -n "$kind" ] && [ "$rc" = 0 ] && [ -n "$out" ]; then
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        ok=0; for t in "${tags[@]}"; do [ "$t" = "$want" ] && ok=1; done
        [ "$ok" -eq 1 ] || { echo "ATRAPA: odpowiedzi '$want' NIE MA na oferowanej liscie: ${tags[*]}" >> "$NR_DIR/wt.log"; echo "ATRAPA: '$want' spoza listy" >&2; exit 255; }
    done <<<"$(printf '%s' "$out" | tr '|' '\n')"
fi
printf '%s' "$out" | tr '|' '\n' >&2
exit "$rc"
EOF
cat > "$NR/bin/zb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${NR_DIR:?}/zb.log"
case "$1" in
    check-source)   if [ -e "$NR_DIR/installed" ]; then cat "$NR_FIX/check-source-pkg.json"; else cat "$NR_FIX/${NR_CHECK:-check-source-pkg.json}"; fi ;;
    list-datasets)  if [ "$2" = "--json" ]; then cat "$NR_FIX/list-datasets.json"; else cat "$NR_FIX/list-datasets-pve9b.json"; fi ;;
    list-profiles)  cat "$NR_FIX/list-profiles.json" ;;
    delete-relation) case " $* " in *" --yes "*) : > "$NR_DIR/freed-$2"; echo "delete-relation: '$2' is gone." ;; *) echo "delete-relation '$2' (state=removed, peer=192.168.28.99):"; echo "plan only." ;; esac ;;
    status)         if [ -n "${NR_STATUS:-}" ]; then cat "$NR_STATUS"
                    elif [ -e "$NR_DIR/freed-192.168.28.99" ]; then sed 's/"name": *"192.168.28.99"/"name":"zwolniona"/' "$NR_FIX/status.json"
                    elif [ -n "${NR_FLAT:-}" ]; then sed 's/"profile": *"default"/"profile":"d30h24"/g' "$NR_FIX/status.json"     # konto root "plaskie"
                    else cat "$NR_FIX/status.json"; fi ;;
    --source=*)     case "$1" in --source=*:*) ;; *)   # kopia lokalna: bez hosta, bez praw
                        case " $* " in *" --install "*) echo ">>> atrapa: lokalna zainstalowana"; exit 0 ;; *) echo "Plan lokalnego backupu (atrapa)"; exit 0 ;; esac ;; esac
                    case " $* " in
                        *" --install "*) case " $* " in
                                *" --grant-remotely "*) echo ">>> atrapa: zainstalowano"; exit 0 ;;
                                *) echo "FATAL: the source has GRANTED nothing yet: on the source run"; echo "    deploy.sh --commit-scope=pve10"; exit 1 ;;
                            esac ;;
                        *) echo "RUX plan (atrapa)"; exit 0 ;;
                    esac ;;
    prepare-source) : > "$NR_DIR/installed"; echo "prepared" ;;
    source-pruners) [ -n "${NR_PRUNERS:-}" ] && printf '%b' "$NR_PRUNERS"; exit 0 ;;
    save-profile)   echo "save-profile: ok (atrapa)" ;;
    delete-profile) echo "delete-profile: ok (atrapa)" ;;
    set-datasets)   echo ">>> atrapa: set-datasets" ;;
    *)              echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
# Okno-drzewo wyboru datasetow (tui/tree.py, curses; X12) bez terminala -- jak $ER/bin/grid
# dla tabel, tylko wspolne dla kreatorow nr/rp/er (rp i er dostaja kopie; stan trzyma
# $NR_DIR danego kreatora): kazde wywolanie okna bierze KOLEJNA linie klawiszy z
# $NR_DIR/treekeys (brak linii = Esc), jedzie PRAWDZIWYM tree.py w trybie --keys, a jego ekran
# z liniami MSG dopisuje do $NR_DIR/tree.log (stdout kreatora zostaje czysty). Kod wyjscia =
# kod tree.py (0 Dalej, 1 Wstecz); linia "RC:" w dzienniku mowi to samo czytajacemu sam dziennik.
cat > "$NR/bin/tree" <<'EOF'
#!/bin/bash
n=$(cat "$NR_DIR/tree.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$NR_DIR/tree.n"
k=$(sed -n "${n}p" "$NR_DIR/treekeys" 2>/dev/null); [ -n "$k" ] || k=esc
pv=""; for a in "$@"; do [ "$pv" = --spec ] && cp "$a" "$NR_DIR/tree-spec.last"; pv="$a"; done
"$TREE_PY" "$TREE_REPO/tui/tree.py" --keys "$k" "$@" >> "$NR_DIR/tree.log"
rc=$?
echo "RC: $rc" >> "$NR_DIR/tree.log"
exit "$rc"
EOF
chmod +x "$NR/bin/whiptail" "$NR/bin/zb" "$NR/bin/tree"
nr_run() {   # <plik odpowiedzi jako tekst> [ENV=...] -> stdout kreatora; dzienniki w $NR
    rm -f "$NR/wt.log" "$NR/wt.n" "$NR/zb.log" "$NR/installed" "$NR"/freed-* "$NR"/new-relation-*.cmd "$NR/tree.n" "$NR/tree.log" "$NR/treekeys" "$NR/tree-spec.last"
    printf '%s' "$1" > "$NR/answers"; shift
    ( export HOME="$NR" NR_DIR="$NR" NR_FIX="$P10" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb" PYTHON="$PY" "$@"
      # Drzewo wyboru datasetow (tui/tree.py) bez terminala: klawisze z NR_TREE, jedna linia
      # na wywolanie okna, linie rozdzielone '|' (jak odpowiedzi); brak linii = Esc.
      printf '%s\n' "${NR_TREE:-}" | tr '|' '\n' > "$NR/treekeys"
      export TREE_PY="$PY" TREE_REPO="$REPO" ZFS_TREE="$NR/bin/tree"
      # Tabela retencji zrodla (tui/grid.py, curses) bez terminala: klawisze z NR_GRID_KEYS,
      # domyslnie Enter = Dalej bez zmian (zrodlo jak cel).
      export ZFS_GRID="$PY $REPO/tui/grid.py --keys ${NR_GRID_KEYS:-enter}"
      bash "$NRS" ) 2>"$NR/err" </dev/null
    local rc=$?
    grep -- ' --install --yes$' "$NR/zb.log" 2>/dev/null | sed 's/^/CMD: /; s/$/ /'
    return "$rc"
}
T=$'\t'
# Pola karty z domyslnymi odpowiedziami (U25): cel, szablon, [tabela retencji zrodla: nie whiptail],
# nazwa, konto, checklista ustawien, edytor prefiksow, KARTA (create), podsumowanie, plan (WYKONAJ)
NRT="0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
"
# Krok 4 to od X12 jedno okno-drzewo (tui/tree.py), nie lista whiptaila: w odpowiedziach
# whiptaila nie ma po nim zadnej linii, a klawisze drzewa ida w NR_TREE (wywolania rozdziela '|').
# NRTK = dawne "wybierz hdd/test-kreator, next": goto: ustawia kursor, Spacja zaznacza, Enter = Dalej.
NRTK='goto:hdd/test-kreator,space,enter'
# W17 (wlasciciel 2026-10-11): zrodlo ZASZYFROWANE -> w "Ustawieniach dodatkowych" pozycja
# "Wyslij zaszyfrowane" ZAZNACZONA domyslnie, komenda z --raw; odznaczona -> bez --raw;
# kontrola: zrodlo niezaszyfrowane -> pozycji nie ma.
NRE="$(mktemp -d)"; cp "$P10"/*.json "$NRE/"
"$PY" - "$NRE/list-datasets-pve9b.json" <<'PYEOF'
import sys, json
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in d["datasets"]:
    x["encryption"] = "aes-256-gcm" if x["name"] == "hdd/test-kreator" else "off"
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
w17_ans() {   # <odpowiedz checklisty "Ustawienia dodatkowe">
    printf '%s' "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}$1
0${T}__done__
1${T}
0${T}create
0${T}
"; }
W17A=$(nr_run "$(w17_ans 'grant|raw')" NR_FIX="$NRE" NR_TREE="$NRTK"); W17L1="$(grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
W17B=$(nr_run "$(w17_ans 'grant')" NR_FIX="$NRE" NR_TREE="$NRTK")
W17C=$(nr_run "$(w17_ans 'grant')" NR_TREE="$NRTK"); W17L3="$(grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
# W17D (kampania wariantow 2026-10-22): zaszyfrowane zrodlo, admin NIE zaglada do Zaawansowanych
# -- domyslne --raw ustawialo sie dopiero w oknie Dodatkowe, wiec komenda szla BEZ --raw (kopia
# odszyfrowana na kolektorze). Teraz domyslne liczy sie po wyborze datasetow.
W17D=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}create
0${T}
" NR_FIX="$NRE" NR_TREE="$NRTK")
# Karta przycina wartosc (szerokosc 76); na main po 'zamrażanie,' stoi 'pomijane', tu 'zaszyfrowane'.
if has "$W17D" "CMD: " && has "$W17D" " --raw " && ! grep -qF 'Ustawienia dodatkowe' "$NR/wt.log" \
   && grep -qF 'zamrażanie, zas' "$NR/wt.log"; then
    ok "new-relation: W17 zaszyfrowane zrodlo bez wchodzenia w Zaawansowane -- komenda i tak z --raw"
else
    bad "new-relation: W17 raw bez Zaawansowanych" "$W17D" "$(grep -F "Zaawansowane" "$NR/wt.log" | head -1 | cut -c1-700)"
fi
if has "$W17A" " --raw " && has "$W17L1" ' ~ raw ~ ' && hasE "$W17L1" 'raw ~ [^~]* ~ ON' \
   && ! has "$W17B" " --raw " && has "$W17B" "CMD: " && ! has "$W17L3" ' ~ raw ~ ' && ! has "$W17C" " --raw "; then
    ok "new-relation: W17 zaszyfrowane zrodlo -- 'Wyslij zaszyfrowane' zaznaczone domyslnie, --raw w komendzie; odznaczone = bez --raw; zwykle zrodlo = bez pozycji"
else
    bad "new-relation: W17 raw" "$W17A" "$W17L1" "$W17B" "$W17L3"
fi
rm -rf "$NRE"

# A>B>C (wlasciciel 2026-10-20): backup ze zrodla, ktore ma juz migawki NASZEJ rodziny
# (magazyn kopii innego kolektora) -- kreator poleca passive-flat i w podsumowaniu pisze
# UWAGA LANCUCH, gdy wybrano szablon stemplujacy. Kontrola: ta sama jazda bez rodziny na
# zrodle (tylko reczne migawki) -- ani polecenia, ani ostrzezenia.
NRC="$(mktemp -d)"; cp "$P10"/*.json "$NRC/"
"$PY" - "$NRC/list-datasets-pve9b.json" <<'PYEOF'
import sys, json, time
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in d["datasets"]:
    x["own_snapshots"] = 5 if x["name"] == "hdd/test-kreator" else 0
    x["family_snapshots"] = 5 if x["name"] == "hdd/test-kreator" else 0
    # 2026-10-24: wiek najnowszej migawki rodziny (okno "Migawki naszej rodziny już są na źródle")
    x["family_newest"] = int(time.time()) - 7200 if x["name"] == "hdd/test-kreator" else 0
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
# szablon passive-flat jest na kazdym hoscie (profiles/), w fixture go nie bylo
"$PY" - "$NRC/list-profiles.json" <<'PYEOF'
import sys, json, copy
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
if not any(x.get("name") == "passive-flat" for x in d["profiles"]):
    x = copy.deepcopy(d["profiles"][0]); x["name"] = "passive-flat"; d["profiles"].append(x)
# od 2026-10-22 passive-flat jest UKRYTY (hidden = yes) -- przy lancuchu i tak ma byc na liscie
for x in d["profiles"]:
    if x.get("name") == "passive-flat":
        x["hidden"] = "yes"
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
# 2026-10-24: przy rodzinie na zrodle jest okno "Migawki naszej rodziny już są na źródle":
# chain = ktos je robi, own = resztki, robie wlasne. Od 2026-10-29 zaraz po Datasetach, PRZED
# "Dokąd" (wlasciciel: po wyborze celu operator bral je za przeszkode w celu).
nrc_ans() {   # <odpowiedz w oknie migawek: chain|own> [tryb: backup] -> odpowiedzi kreatora backupu ze zrodlem z rodzina
    printf '%s' "0${T}${2:-backup}
0${T}192.168.28.98
0${T}
0${T}$1
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
"; }
NRCA=$(nr_run "$(nrc_ans chain)" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCW="$(cat "$NR/wt.log")"
# okno pytajace: tytul, menu z tagami chain/own, wiek najnowszej migawki z 4. kolumny own.tsv
NRCQ="$NRCW"
NRCOA=$(nr_run "$(nrc_ans own)" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCOW="$(cat "$NR/wt.log")"
# Dwa korzenie (kampania pve10, 2026-10-29): build_argv ma `local IFS=,`, a odpowiedz byla
# przypisana do "${B_ROOT[*]}" ze spacja -- przy dwoch datasetach --own-snapshots ginal.
NRCO2=$(nr_run "$(nrc_ans own)" NR_FIX="$NRC" NR_TREE='goto:hdd/test-kreator,space,goto:hdd/vm-disks,space,enter')
# sync + szablon default + odpowiedz chain: lustro bedzie PASYWNE, bez --own-snapshots
NRCS=$(nr_run "0${T}sync
0${T}192.168.28.98
0${T}
0${T}chain
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCSW="$(cat "$NR/wt.log")"
"$PY" - "$NRC/list-datasets-pve9b.json" <<'PYEOF'
import sys, json
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in d["datasets"]:
    x["family_snapshots"] = 0
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
NRCB=$(nr_run "$(w17_ans 'grant')" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCW0="$(cat "$NR/wt.log")"
if has "$NRCW" '[polecany]' && has "$NRCW" 'resztki starej relacji' && has "$NRCW" 'UWAGA ŁAŃCUCH' && has "$NRCW" 'pole Harmonogram -> passive-flat' \
   && ! has "$NRCW0" 'ŁAŃCUCH' && ! has "$NRCW0" '[polecany]' && has "$NRCB" 'CMD: ' \
   && has "$NRCA" 'CMD: ' && ! has "$NRCA" '--own-snapshots'; then
    ok "new-relation: backup z magazynu kopii (nasza rodzina na zrodle) -- polecany passive-flat, UWAGA LANCUCH w podsumowaniu; reczne migawki -- bez tego"
else
    bad "new-relation: lancuch dla backupu" "$(printf '%s' "$NRCW" | grep -E 'polecany|ŁAŃCUCH' | cut -c1-200)" "$(printf '%s' "$NRCW0" | grep -E 'polecany|ŁAŃCUCH' | cut -c1-200)" "$NRCA"
fi
if has "$NRCO2" 'hdd/test-kreator,hdd/vm-disks' && has "$NRCO2" ' --own-snapshots '; then
    ok "new-relation: 'own' przy DWOCH datasetach -- komenda niesie --own-snapshots (build_argv z IFS=, nie gubi odpowiedzi)"
else
    bad "new-relation: own przy dwoch datasetach" "$(printf '%s' "$NRCO2" | grep -a 'CMD' | cut -c1-300)"
fi
if has "$NRCOA" 'CMD: ' && has "$NRCOA" ' --own-snapshots ' && has "$NRCOW" 'WŁASNE MIGAWKI' && ! has "$NRCOW" 'UWAGA ŁAŃCUCH'; then
    ok "new-relation: odpowiedz 'own' w oknie migawek rodziny -- komenda niesie --own-snapshots, podsumowanie mowi WŁASNE MIGAWKI (kontrola: 'chain' = bez flagi)"
else
    bad "new-relation: own -> --own-snapshots" "$NRCOA" "$(printf '%s' "$NRCOW" | grep -E 'WŁASNE|ŁAŃCUCH' | cut -c1-200)"
fi
if has "$NRCS" 'CMD: ' && ! has "$NRCS" '--own-snapshots' && has "$NRCSW" 'lustro będzie PASYWNE'; then
    ok "new-relation: synchro + odpowiedz 'chain' + szablon default -- podsumowanie mowi 'lustro będzie PASYWNE', komenda bez --own-snapshots"
else
    bad "new-relation: synchro chain -> PASYWNE" "$NRCS" "$(printf '%s' "$NRCSW" | grep -E 'PASYWNE|ŁAŃCUCH|ATRAPA' | cut -c1-200)"
fi
if has "$NRCQ" 'Migawki naszej rodziny już są na źródle' && has "$NRCQ" '--notags' && has "$NRCQ" ' ~ chain ~ ' && has "$NRCQ" ' ~ own ~ ' \
   && has "$NRCQ" 'najnowsza' && has "$NRCQ" '2 godz. temu' && ! has "$NRCW0" 'najnowsza'; then
    ok "new-relation: okno 'Migawki naszej rodziny już są na źródle' -- menu chain/own, w tekscie 'najnowsza' z wiekiem z 4. kolumny own.tsv (family_newest)"
else
    bad "new-relation: okno migawek rodziny" "$NRCQ"
fi
rm -rf "$NRC"

# MIGAWKI ZDALNIE (REV-20261017-152 runda 3): ten sam przebieg co backup, bez kroku
# "Dokąd", bez edytora pomijanych prefiksów i retencji "w źródle kopii" (szablon JEST
# retencją źródła). Domyślny szablon d7h24 (default ma drabinę GFS na szczeblu i jest
# odrzucany przy aktywacji). Komenda: --mode=snaponly, bez --target.
SOW="0${T}snaponly
0${T}192.168.28.98
0${T}
0${T}d7h24
0${T}pve9b
0${T}create
0${T}
"
SOWO=$(nr_run "$SOW" NR_TREE="$NRTK")
SOWP="$(grep -F 'Jak długo trzymać migawki na źródle' "$NR/wt.log" | head -1)"
if has "$SOWO" "CMD: " && has "$SOWO" " --mode=snaponly " && ! has "$SOWO" "--target=" && has "$SOWO" " --grant-remotely " \
   && ! has "$SOWO" "--exclude-family" && ! has "$SOWO" " --raw " \
   && grep -qF 'Gdzie robić migawki na' "$NR/tree.log" && grep -qF '[x] z migawkami' "$NR/tree.log" && ! grep -qF 'Co kopiować z' "$NR/tree.log" \
   && grep -qF 'Pełny plan (sekcje configu, linie crona)' "$NR/wt.log" && ! grep -qF 'lustro: ta sama' "$NR/wt.log" \
   && has "$SOWP" '--default-item ~ d7h24' && ! grep -q 'Dokąd\|Pomijane prefiksy\|W ŹRÓDLE KOPII' "$NR/wt.log" \
   && grep -q 'Jak długo trzymać migawki na źródle' "$NR/wt.log"; then
    ok "new-relation: Migawki zdalnie -- --mode=snaponly bez --target, bez pola Dokąd/prefiksów/retencji źródła kopii, domyślny szablon d7h24, jest okno 'Jak długo trzymać migawki na źródle'"
else
    bad "new-relation: Migawki zdalnie" "$SOWO" "$SOWP" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | head -12 | tr '\n' ';')"
fi
NRTS="0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
"
# KOSZYK MIEJSC (2026-09-18, trzecia wersja tego dnia). Wlasciciel: jedna lista kratek
# byla mylaca; pytanie "co kopiowac?" tylko dla datasetow z dziecmi tez -- "czysty
# Proxmox, wskazuje rpool/data, zeby kopiowal maszyny, ktorych tam jeszcze nie ma".
# Zmierzone na pve10<-pve11: dataset zalozony pod zrodlem PO relacji kopiuje sie sam,
# w -R i w -r. Pozycja = MIEJSCE; dodanie nie zadaje pytan; wyjatki to akcja koszyka.
# 1. miejsce z dziecmi + wyjatek + puste miejsce
# X12: koszyk to jedno drzewo (tui/tree.py); dawne "wybierz hdd/data, exc, mail, add,
# hdd/test-kreator, next" to klawisze: Spacja na hdd/data (miejsce), Spacja na mail (pod
# miejscem = wyjatek), Spacja na hdd/test-kreator (drugie miejsce), Enter. Ostatni goto tylko
# stawia kursor na zvolu, zeby ekran (tree.log) pokazal wiersz z zvolem; nic nie zaznacza.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
${NRT}" NR_TREE='goto:hdd/data,space,goto:hdd/data/mail,space,goto:hdd/test-kreator,space,goto:hdd/vm-disks/vm-201-disk-0,enter'); NRRC=$?
if [ "$NRRC" -eq 0 ] && has "$NROUT" "CMD: --source=192.168.28.98:hdd/data,hdd/test-kreator --target=hdd/backups --landing=pve9b --profile=default --name=pve9b --exclude-child=^hdd/data/mail\$ --exclude-family=__replicate_,vzdump,__migration__ --grant-remotely --install --yes " && ! has "$NROUT" "--recursive" && ! hasE "$NROUT" 'exclude-child=[^ ]*[(|]'; then
    ok "new-relation: koszyk -- miejsca w JEDNYM --source po przecinku, odznaczone dziecko jako --exclude-child=^nazwa\$ (zakotwiczone, bez ( | -- wzorzec jedzie nieocytowany do crona)"
else
    bad "new-relation: koszyk, droga glowna" "rc=$NRRC" "$NROUT" "$(cat "$NR/err")" "$(cat "$NR/wt.log")"
fi
# RELACJA = CONFIG (2026-10-26): po założeniu z [-] kreator zapisuje zakres jak okno zmiany --
# jedno set-datasets z pozycjami drzewa (hdd/data [-] bez mail, hdd/test-kreator [x]).
NRSD="$(grep '^set-datasets ' "$NR/zb.log" 2>/dev/null)"
if [ "$(printf '%s\n' "$NRSD" | grep -c .)" -eq 1 ] && has "$NRSD" "set-datasets pve9b --dataset=hdd/data:no " \
   && has "$NRSD" " --dataset=hdd/test-kreator:flat " && ! has "$NRSD" "hdd/data/mail" && has "$NRSD" " --yes"; then
    ok "new-relation: z [-] po założeniu jedno set-datasets z pozycjami drzewa (wyłączone dziecko poza listą)"
else
    bad "new-relation: set-datasets po założeniu z [-]" "$NRSD" "$(cat "$NR/zb.log")"
fi
# Podsumowanie mówi to samo, co zapisze set-datasets: lista [x]/[-], nie "BEZ: mail".
if grep -qF '[-] hdd/data ' "$NR/wt.log" && grep -qF '[x] hdd/test-kreator ' "$NR/wt.log" && ! grep -qF 'BEZ: mail' "$NR/wt.log"; then
    ok "new-relation: podsumowanie z [-] pokazuje pozycje [x]/[-] jak okno zmiany"
else
    bad "new-relation: podsumowanie z [-]" "$(grep -F 'obejmie' -A4 "$NR/wt.log")"
fi
NRTL="$(cat "$NR/tree.log" 2>/dev/null)"
if ! grep -qF -- '--radiolist' <(grep -F 'Co kopiować z' "$NR/wt.log") && ! grep -qF 'Jak kopiować' "$NR/wt.log" && ! has "$NRTL" 'Jak kopiować'; then
    ok "new-relation: dodanie miejsca NIE zadaje pytan -- w polu Datasety nie ma ani 'co kopiowac?', ani -R/-r (to 'jak', nie 'co')"
else
    bad "new-relation: pytanie w polu Datasety""$(grep -F -- '--radiolist' "$NR/wt.log")" "$NRTL"
fi
# Dawna "lista miejsc" (whiptail) to teraz ekran drzewa w tree.log: tytul kroku, wciecie,
# rozmiar, zvol i legenda "POWSTANIE". Dawne "druga lista nie oferuje tego, co koszyk juz
# obejmuje" nie ma odpowiednika -- w drzewie to, co obejmuje miejsce, stoi w tym samym oknie jako [x].
if has "$NRTL" 'Co kopiować z pve9b?' && has "$NRTL" 'także przyszłymi' \
   && hasE "$NRTL" '- \[-\] data +[0-9.]+[KMG] ' && hasE "$NRTL" 'vm-201-disk-0 +zvol [0-9.]+[KMGB] ' \
   && hasE "$NRTL" '\[x\] docs' && hasE "$NRTL" '\[x\] photos'; then
    ok "new-relation: lista miejsc = drzewo z kratkami (tytul okna, wciecie, rozmiar, zvol) i mowi wprost 'POWSTANIE'; to, co obejmuje miejsce, stoi w tym samym oknie jako [x]"
else
    bad "new-relation: drzewo miejsc" "$NRTL"
fi
if has "$NRTL" '[ ] mail' && has "$NRTL" 'pominięte: 1' && hasE "$NRTL" '\[x\] test-kreator' && has "$NRTL" 'Sposób: każdy dataset osobno (-R)' \
   && has "$NRTL" 'Wybrane miejsca: 2'; then
    ok "new-relation: okno koszyka POKAZUJE, co dzis lezy pod miejscem i co jest pomijane (odznaczona 'mail', 'pominięte: 1'), puste miejsce jako [x] bez dzieci, 'Sposób: każdy dataset osobno (-R)' jako akcja okna (S)"
else
    bad "new-relation: okno koszyka" "$NRTL"
fi
# Dawne okna wyjatkow (list_editor: 'co pominąć' / 'czego NIE kopiować', 'Dodaj' oferujace tylko to, co pod
# miejscem) nie istnieja -- wyjatek to odznaczona kratka pod zaznaczonym miejscem, wiec "oferuje tylko to,
# co pod miejscem" wynika z drzewa. Zostaje to, co liczy sie dla czasownika: komenda niesie DOKLADNIE
# jeden --exclude-child (dla mail) i nic z hdd/ct.
if has "$NROUT" " --exclude-child=^hdd/data/mail\$ " && [ "$(printf '%s' "$NROUT" | grep '^CMD: ' | grep -o 'exclude-child' | wc -l)" -eq 1 ] \
   && ! has "$(printf '%s' "$NROUT" | grep '^CMD: ')" 'hdd/ct' && has "$NROUT" "--source=192.168.28.98:hdd/data,hdd/test-kreator "; then
    ok "new-relation: wyjatek = odznaczony dataset pod miejscem; w komendzie dokladnie jeden --exclude-child (mail), nic z hdd/ct, miejsca w jednym --source"
else
    bad "new-relation: wyjatki w komendzie" "$(printf '%s' "$NROUT" | grep '^CMD: ')" "$NRTL"
fi
# 2. puste miejsce samo: akcji 'Wyjatki' NIE MA (przyszlego nie da sie wskazac), synchro z portem
NROUT=$(nr_run "0${T}sync
0${T}192.168.28.98:2222
0${T}
${NRTS}" NR_TREE="$NRTK")
# Dawne "bez akcji 'Wyjatki'" = w drzewie nic nie jest pominiete: ekran nie ma 'pominięte: 1'.
if has "$NROUT" "CMD: --source=192.168.28.98:2222:hdd/test-kreator --mode=sync --profile=default --name=pve9b --exclude-family=" && ! has "$NROUT" "--target" && ! has "$NROUT" "exclude-child" && grep -q '^check-source 192.168.28.98:2222 --json$' "$NR/zb.log" \
   && has "$(cat "$NR/tree.log")" 'pominięte: 0' && ! has "$(cat "$NR/tree.log")" 'pominięte: 1'; then
    ok "new-relation: miejsce, pod ktorym dzis nic nie ma -> koszyk BEZ akcji 'Wyjatki'; synchro = --mode=sync, port w adresie"
else
    bad "new-relation: puste miejsce / synchro" "$NROUT" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log")"
fi
# 3. wyjatki otwarte drugi raz pamietaja stan (odznaczone wraca odznaczone)
# X12: dawne okna wyjatkow zniknely. "Otwarte drugi raz" to teraz ponowne otwarcie pola Datasety:
# U66: Wstecz z menu "Dokad" (odpowiedz `1`) to POPRZEDNI krok -- drzewo, ktore
# dostaje z koszyka ten sam wybor -- wiec drugi ekran w tree.log ma subvol-302 znow odznaczony,
# a 301 zaznaczony. Dwa wywolania okna = dwie linie NR_TREE.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
1${T}
${NRT}" NR_TREE='goto:hdd/ct,space,goto:hdd/ct/subvol-302-disk-0,space,enter|enter')
NRTL="$(cat "$NR/tree.log" 2>/dev/null)"
if has "$NROUT" " --exclude-child=^hdd/ct/subvol-302-disk-0\$ " && ! has "$NROUT" "subvol-301-disk-0" \
   && [ "$(grep -c '^┌─' "$NR/tree.log")" -eq 2 ] && [ "$(grep -cF '[ ] subvol-302-disk-0' "$NR/tree.log")" -eq 2 ] \
   && [ "$(grep -cF '[x] subvol-301-disk-0' "$NR/tree.log")" -eq 2 ] && ! has "$NRTL" '[ ] subvol-301-disk-0'; then
    ok "new-relation: drzewo otwarte drugi raz (Wstecz z kroku Dokad, U66) pamieta stan -- odznaczone 302 wraca odznaczone, 301 zaznaczone; w komendzie tylko 302"
else
    bad "new-relation: stan wyjatkow" "$NROUT" "$NRTL"
fi
# 3b. miejsce dodane PO swoim dziecku: pytanie o zastapienie, bez sprzecznosci w komendzie
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
${NRT}" NR_TREE='goto:hdd/data/docs,space,goto:hdd/data,space,enter')
# X12: pytania 'Zastap' (okno 'obejmuje to, co już wybrane') juz nie ma -- rodzic po prostu wchlania
# dziecko. Zostaje to, co liczy sie dla komendy (--source = samo miejsce, bez dziecka); ekran mowi
# to samo: jedno wybrane miejsce, nic pominietego.
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/data --target" && ! has "$NROUT" "hdd/data/docs" \
   && has "$(cat "$NR/tree.log")" 'Wybrane miejsca: 1   pominięte: 0'; then
    ok "new-relation: miejsce dodane po wlasnym dziecku -> rodzic wchlania dziecko bez pytania; w komendzie zostaje samo miejsce"
else
    bad "new-relation: zastapienie dziecka miejscem" "$NROUT" "$(cat "$NR/tree.log")"
fi
# 3c. pominiety dataset Z WLASNYMI dziecmi = dwa wzorce: ^nazwa$ i ^nazwa/
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
${NRT}" NR_TREE='goto:hdd,space,goto:hdd/ct/subvol-301-disk-0,space,goto:hdd/ct,space,space,enter')
NRTL="$(cat "$NR/tree.log" 2>/dev/null)"
# Ekran: wyjatek hdd/ct (odznaczony) wchlonal wczesniejszy wyjatek 301 -- 'pominięte: 1', nie 2.
if has "$NROUT" "CMD: --source=192.168.28.98:hdd --target=hdd/backups --landing=pve9b --profile=default --name=pve9b --exclude-child=^hdd/ct\$ --exclude-child=^hdd/ct/ --exclude-family" && [ "$(printf '%s' "$NROUT" | grep '^CMD: ' | grep -o 'exclude-child' | wc -l)" -eq 2 ] \
   && ! has "$NROUT" "subvol-301-disk-0" && has "$NRTL" '[ ] ct' && has "$NRTL" 'pominięte: 1' && ! has "$NRTL" 'pominięte: 2'; then
    ok "new-relation: wyjatek z dziecmi = ^nazwa\$ i ^nazwa/; odznaczenie przodka zdejmuje wczesniej odznaczonego potomka (jego dzieci nie dostaja wlasnych wzorcow)"
else
    bad "new-relation: pominiety z dziecmi" "$NROUT" "$NRTL"
fi
# 3d. zaznacz i odznacz jedyne miejsce -> Enter odmawia, Esc = Wstecz; Wstecz x3 = wyjscie
# X12: dawne "Usun pozycje -> znow lista miejsc" to Spacja na zaznaczonym miejscu (znika) i Esc.
# U66: Wstecz z drzewa = poprzedni krok (host, odpowiedz `1` = Wstecz), z rodzaju (`1`) pytanie
# "przerwac?" (`0` = Przerwij). Okno drzewa wola sie RAZ.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
1${T}
1${T}
0${T}
" NR_TREE='goto:hdd/test-kreator,space,goto:hdd/test-kreator,space,esc'); NRRC=$?
# Dawne "lista miejsc pojawia sie drugi raz" -- okna listy juz nie ma. Zostaje: kreator konczy sie
# rc=1, drzewo bylo wolane dokladnie raz (jeden ekran w tree.log) i skonczylo sie Wstecz (rc=1 tree.py).
if [ "$NRRC" -eq 1 ] && [ "$(grep -c '^┌─' "$NR/tree.log")" -eq 1 ] && [ "$(grep -c '^RC: 1$' "$NR/tree.log")" -eq 1 ] \
   && ! grep -q '^RC: 0$' "$NR/tree.log" && has "$(cat "$NR/tree.log")" 'Wybrane miejsca: 0' \
   && has "$NROUT" "przerwane, nic nie zmieniono" && [ "$(grep -c 'Z którego hosta? ~ --ok-button' "$NR/wt.log")" -eq 2 ] \
   && grep -qF 'Nowa relacja: przerwać?' "$NR/wt.log"; then
    ok "new-relation: zdjecie jedynego miejsca i Esc w drzewie = Wstecz (jedno wywolanie okna, rc=1); Wstecz = poprzedni krok (host), Wstecz z rodzaju pyta o przerwanie (U66)"
else
    bad "new-relation: usuwanie z koszyka" "rc=$NRRC" "$(cat "$NR/tree.log" 2>/dev/null)" "$(cat "$NR/wt.log")"
fi
# 3e. pola od celu do konta: nazwa zajeta -> odmowa i powrot do pola; Wstecz z nazwy na KARTE
#     (U25), z karty `profile` otwiera szablon (bez pytania o spojnosc -- usunieta, patrz
#     "lista szablonow" nizej); zmiana szablonu otwiera ponownie retencje zrodla (tabela, nie
#     whiptail); ponowne Dalej NIE czyta list-profiles/status od nowa.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}
0${T}profile
0${T}d30
0${T}adv
0${T}acct
0${T}zfsbackup
0${T}extra
0${T}grant|quies
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE="$NRTK")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/test-kreator --target=hdd/backups --landing=pve9b --profile=d30 --name=pve9b --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --grant-remotely --grant-quiesce --install --yes " \
   && ! grep -qF 'Pod tą nazwą relacja będzie widoczna' "$NR/wt.log" && [ "$(grep -c '^list-profiles' "$NR/zb.log")" -eq 1 ] && [ "$(grep -c '^status' "$NR/zb.log")" -eq 1 ]; then
    ok "new-relation: pola cel-konto -- nazwa = host po drugiej stronie, bez okna nazwy (wlasciciel 2026-10-29), z podsumowania szablon zmienia wybor (d30, U66), konto delegowane = --local-user; list-profiles i status czytane RAZ na przebieg (cofanie nie kaze czekac od nowa)"
else
    bad "new-relation: pola cel-konto" "$NROUT" "$(cat "$NR/zb.log")" "$(grep -F 'Nazwa' "$NR/wt.log" | cut -c1-200)"
fi
# krok 6 -- WSZYSTKIE szablony na jednej liscie, bez pytania o spojnosc, znaczniki
# [zamraża]/[drabina] przy kazdym (wlasciciel, uwaga 15: "nie moglem znalezc
# d30h24" -- filtrowanie po spojnosci i plaskosci hosta je chowalo).
if ! grep -qF 'Spójność migawek' "$NR/wt.log"; then
    ok "new-relation: krok 6 nie pyta juz o spojnosc migawek -- jedna lista, wszystkie szablony"
else
    bad "new-relation: krok 6 wciaz pyta o spojnosc" "$(grep -F 'Spójność migawek' "$NR/wt.log" | head -1 | cut -c1-300)"
fi
NRL6="$(grep -F 'Jak długo trzymać w celu' "$NR/wt.log" | head -1)"
printf '%s' "$NRL6" > "$NR/step6.line"
if "$PY" - "$NR/step6.line" <<'PYEOF'
import sys
parts = open(sys.argv[1], encoding="utf-8").read().split(" ~ ")
def desc(tag):
    # OSTATNIE wystapienie: lista idzie po --menu, a "default" stoi wczesniej
    # jako wartosc --default-item -- pierwsze trafienie bylo "--menu", i stara
    # asercja (brak znacznikow) przechodzila na nim przypadkiem.
    for i in range(len(parts) - 2, -1, -1):
        if parts[i] == tag:
            return parts[i + 1]
    return None
d_def = desc("default"); d_30 = desc("d30"); d_g = desc("d7h24-gfs")
# K5: [drabina] stoi przy JEDNEJ drabinie (default), nie przy retencji w szczeblach
# -- ani przy d30 (N najnowszych), ani przy -gfs (rodzina na szczebel, kazda z GFS).
ok = d_def is not None and "[zamraża]" not in d_def and "[drabina]" in d_def
ok = ok and d_30 is not None and "[zamraża]" in d_30 and "[drabina]" not in d_30
ok = ok and d_g is not None and "[drabina]" not in d_g and "[płaski]" not in d_g
# kampania 3 (2026-10-22, 80x24): sposob liczenia stoi PRZED opisem retencji, wiec przy
# przycieciu wiersza nie ginie (full i m12w4d7h24-gfs wygladaly tak samo)
ok = ok and "[N najnowszych]" in d_30 and 0 <= d_30.find("[N najnowszych]") < d_30.find("30 dni")
ok = ok and "[GFS]" in d_g and d_g.find("[GFS]") < d_g.find("24 godz.")
# kampania 3 (2026-10-23): pytanie okna mowi "Jak dlugo trzymac" -- na liscie same liczby
ok = ok and "trzyma" not in d_30 and "trzyma" not in d_g
sys.exit(0 if ok else 1)
PYEOF
then
    ok "new-relation: krok 6 -- 'default' [drabina] bez [zamraża], 'd30' [zamraża] bez [drabina], 'd7h24-gfs' bez znacznika ksztaltu (K5) -- jedna lista, zaden filtr"
else
    bad "new-relation: krok 6 lista szablonow" "$(printf '%s' "$NRL6" | cut -c1-800)"
fi
if grep -qF 'zamraża: dobowe' "$NR/wt.log"; then
    ok "new-relation: podsumowanie mowi slowami, co wybrany szablon zamraza"
else
    bad "new-relation: podsumowanie bez zamrazania" "$(grep -F 'Szablon:' "$NR/wt.log" | tail -2)"
fi
# Od 2026-10-29 podsumowanie i plan to JEDNO okno (tytul "Plan", przycisk WYKONAJ).
if grep -F -e '--yesno' "$NR/wt.log" | grep -F 'WYKONAJ' | tail -1 | grep -qF 'BACKUP: ' && grep -qF 'Konto: zfsbackup.' "$NR/wt.log" \
   && ! grep -F -e '--yesno' "$NR/wt.log" | grep -F 'WYKONAJ' | tail -1 | grep -qF -- '--scrolltext' \
   && ! grep -qF 'Plan był w poprzednim oknie' "$NR/wt.log" && ! grep -qF 'Pokaż plan' "$NR/wt.log"; then
    ok "new-relation: podsumowanie i plan w JEDNYM oknie z WYKONAJ, bez przewijania, bez 'Plan był w poprzednim oknie' (wlasciciel 2026-10-29); BEZ przewijania (w oknie z --scrolltext Enter nie dziala, dopoki nie przejdziesz Tabem na przyciski -- zmierzone jazda po pty)"
else
    bad "new-relation: podsumowanie" "$(grep -F 'WYKONAJ' "$NR/wt.log" | tail -1 | cut -c1-600)"
fi

# 3j. RETENCJA U ZRODLA (wlasciciel, uwaga 19, 2026-09-24): krok 9 -- "Inna
#     retencja u zrodla" -> menu szczebli profilu CELU z jego liczbami; zmiana
#     liczby > 0 buduje profil pochodny przez save-profile, 0 = --drop-tier
#     (dozwolone tylko, gdy inny szczebel tej samej rodziny wciaz sprzata).
# T1: dobowe 7 -> 3, tygodniowe 4 -> 0 (godzinowe i miesieczne bez zmian).
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_GRID_KEYS=down,right,bs,3,down,left,space,enter NR_TREE="$NRTK")
NRL6SRC="$(grep -F 'Jak długo trzymać w celu' "$NR/wt.log" | head -1)"
if grep -qF 'save-profile --from=default --force --tier=keep_daily --keep=3 --drop-tier=keep_weekly --as=default-src-H24D3M12' "$NR/zb.log" \
   && [ "$(grep -c '^save-profile' "$NR/zb.log")" = 1 ] \
   && printf '%s' "$NROUT" | grep -qF 'TUTAJ (cel)' && printf '%s' "$NROUT" | grep -qF 'U ŹRÓDŁA' \
   && has "$NROUT" '--source-profile=default-src-H24D3M12'; then
    ok "new-relation: retencja zrodla to LICZBY szczebli celu -> profil pochodny przez save-profile, 0 = --drop-tier (wlasciciel, uwaga 19)"
else
    bad "new-relation: retencja zrodla, T1" "$NROUT" "$(cat "$NR/zb.log")"
fi
# T1-age (K1, 2026-10-07): szablon WIEKU. Okno znalo tylko keep i dla -age mowilo
# "nie ma szczebli z liczba do zmiany". Teraz te same szczeble z jednostka, a zapis
# idzie przez --retain=-<jednostka><liczba> (licznik zostaje licznikiem, wiek wiekiem).
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}d7h24-age
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_GRID_KEYS=right,bs,bs,1,2,down,bs,3,enter NR_TREE="$NRTK")
if printf '%s' "$NROUT" | grep -qE '\[X\] godzinowe +24 godz\.' && printf '%s' "$NROUT" | grep -qE '\[X\] dobowe +7 dni' \
   && grep -qF 'save-profile --from=d7h24-age --force --tier=hourly --retain=-h12 --tier=daily --retain=-d3 --as=d7h24-age-src-H12D3' "$NR/zb.log" \
   && ! grep -q -- '--keep=' "$NR/zb.log" \
   && has "$NROUT" '--source-profile=d7h24-age-src-H12D3'; then
    ok "new-relation: retencja zrodla dla szablonu WIEKU -- szczeble z jednostka, zapis przez --retain, nie --keep (K1)"
else
    bad "new-relation: retencja zrodla, T1-age (K1)" "$(grep -F 'zrodle\|źródle' "$NR/wt.log" | tail -2)" "$(cat "$NR/zb.log")"
fi
# profile pochodne (-src-) w fiksturze nie sa szablonami do wyboru w kroku 6
if [ -n "$NRL6SRC" ] && ! has "$NRL6SRC" 'default-src-X ~'; then
    ok "new-relation: profile pochodne (-src-) nie sa szablonami w kroku 6"
else
    bad "new-relation: profil pochodny w liscie kroku 6" "$NRL6SRC"
fi
# T2: szczebla, ktory jako jedyny sprzata rodzine, nie da sie wylaczyc (d30h24:
#     godzinowe i dobowe to DWIE ROZNE rodziny, kazda z jednym szczeblem).
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}d30h24
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_GRID_KEYS=space,enter NR_TREE="$NRTK")
if printf '%s' "$NROUT" | grep -qF 'Nie można wyłączyć: tylko ten szczebel' && ! grep -q '^save-profile' "$NR/zb.log"; then
    ok "new-relation: szczebla, ktory jako jedyny sprzata rodzine, nie da sie wylaczyc"
else
    bad "new-relation: T2 odmowa wylaczenia jedynego szczebla" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log")"
fi
# T3: "Zmien" i te same liczby co tutaj = SRCPROF zostaje pusty, bez osobnego
#     profilu i bez wywolania save-profile (uwaga 2: "Tak, dalej" robi to samo krocej).
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_GRID_KEYS=enter NR_TREE="$NRTK")
if ! grep -q '^save-profile' "$NR/zb.log" && ! has "$NROUT" '--source-profile='; then
    ok "new-relation: retencja zrodla bez zmian = bez osobnego profilu"
else
    bad "new-relation: T3 gotowe bez zmian" "$NROUT" "$(cat "$NR/zb.log")"
fi

# 3f. INNY KOLEKTOR JUZ PRZYCINA (uwaga 4, 2026-10-08): pytanie pada przed planem, nie po
#     seedzie. "Pasywnie" wraca do pola szablonu z wybranym passive (U25: reszta pol jest juz
#     otwarta, wiec po nim od razu karta z `create`); po nim relacja nie
#     przycina zrodla, wiec drugi raz nie pyta, a komenda niesie --profile=passive.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}pasywnie
0${T}passive
0${T}create
0${T}
" NR_PRUNERS='hdd/test-kreator\tzfsbackup-pve10\n' NR_TREE="$NRTK"); NRRC=$?
if [ "$NRRC" -eq 0 ] && has "$NROUT" " --profile=passive " && grep -q '^source-pruners 192.168.28.98 hdd/test-kreator$' "$NR/zb.log" \
   && [ "$(grep -c '^source-pruners' "$NR/zb.log")" = 1 ] \
   && grep -F 'Inny kolektor już przycina' "$NR/wt.log" | grep -qF 'hdd/test-kreator  -- zfsbackup-pve10'; then
    ok "new-relation: konflikt z innym kolektorem wychodzi PRZED planem, z nazwa konta; 'Pasywnie' daje --profile=passive i nie pyta drugi raz"
else
    bad "new-relation: konflikt z innym kolektorem" "rc=$NRRC" "$NROUT" "$(cat "$NR/zb.log")" "$(grep -F 'przycina' "$NR/wt.log" | cut -c1-400)"
fi
# ...a bez konfliktu: pytanie padlo (source-pruners w dzienniku), okna nie ma.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
${NRT}" NR_TREE="$NRTK"); NRRC=$?
if [ "$NRRC" -eq 0 ] && grep -q '^source-pruners ' "$NR/zb.log" && ! grep -qF 'Inny kolektor' "$NR/wt.log" && has "$NROUT" " --profile=default "; then
    ok "new-relation: bez cudzego kolektora sprawdzenie przechodzi bez okna"
else
    bad "new-relation: sprawdzenie bez konfliktu" "rc=$NRRC" "$NROUT" "$(cat "$NR/zb.log")"
fi
# U25: KARTA przed podsumowaniem. Po wypelnieniu wszystkich pol (ten sam przebieg co wyzej) kreator
# pokazuje menu "Relacja (nowa)" z kursorem na `create`, PO oknie "Ustawienia dodatkowe" i PRZED
# "Podsumowanie". Numery linii dziennika: kazde okno to jedna linia, wiec kolejnosc = kolejnosc numerow.
NRLN_X="$(grep -n -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1 | cut -d: -f1)"
NRLN_S="$(grep -n -F 'WYKONAJ' "$NR/wt.log" | grep -F -e '--yesno' | head -1 | cut -d: -f1)"
NRLN_C="$(grep -n -F 'Nowa relacja -- podsumowanie' "$NR/wt.log" | grep -F -e '--menu' | awk -F: -v s="${NRLN_S:-0}" '$1 < s { n = $1 } END { print n }')"
NRCARD="$(sed -n "${NRLN_C:-1}p" "$NR/wt.log")"
if [ -n "$NRLN_X" ] && [ -n "$NRLN_C" ] && [ -n "$NRLN_S" ] && [ "$NRLN_X" -lt "$NRLN_C" ] && [ "$NRLN_C" -lt "$NRLN_S" ] \
   && has "$NRCARD" '--default-item ~ create ~'; then
    ok "new-relation: podsumowanie kreatora z kursorem na create pojawia sie PO 'Ustawienia dodatkowe' (Zaawansowane) i PRZED 'Podsumowanie' (U66)"
else
    bad "new-relation: karta przed podsumowaniem" "extra=$NRLN_X karta=$NRLN_C podsumowanie=$NRLN_S" "$(printf '%s' "$NRCARD" | cut -c1-300)"
fi

# Kampania 2026-10-22 (marudny admin): Esc w pytaniu "Przerwać?" = Zostań, nie przerwanie.
# Wyjdź z kroku 1, Esc w pytaniu -> znowu krok 1; Wyjdź, Przerwij -> koniec.
NROUT=$(nr_run "1${T}
255${T}
1${T}
0${T}
"); NRRC=$?
if [ "$NRRC" -eq 1 ] && [ "$(grep -c 'Nowa relacja: przerwać?' "$NR/wt.log")" -eq 2 ] && [ "$(grep -c 'Jaka relacja?' "$NR/wt.log")" -eq 2 ] \
   && has "$NROUT" "przerwane, nic nie zmieniono"; then
    ok "new-relation: Esc w pytaniu 'Przerwać?' = Zostań (wraca do kroku), przerywa tylko przycisk Przerwij"
else
    bad "new-relation: Esc w pytaniu o przerwanie" "rc=$NRRC" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | tr '\n' ';')"
fi
# U68: "Przegladaj..." w kroku Dokad to DRZEWO w trybie jednej pozycji (wczesniej plaska lista
# whiptaila z obcietymi nazwami). Wnetrza ladowisk innych relacji ukryte i policzone w legendzie.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}__browse__
0${T}default
0${T}pve9b
0${T}create
0${T}
" NR_TREE="$NRTK|goto:hdd,enter")
if has "$NROUT" " --target=hdd " && ! grep -qF 'Dokąd -- przeglądaj ~ --ok-button' "$NR/wt.log" \
   && "$PY" - "$NR/tree-spec.last" <<'PYEOF'
import sys, json
s = json.load(open(sys.argv[1], encoding="utf-8")); names = [d["name"] for d in s["datasets"]]
ok = s.get("single") is True and "hdd" in names and "hdd/backups" in names \
     and not any(n.startswith("hdd/backups/192.168.28.99") for n in names) and "ukryto" in s.get("legend", "") + s.get("cursor_line", "")
sys.exit(0 if ok else 1)
PYEOF
then
    ok "new-relation: Przegladaj w kroku Dokad = drzewo jednej pozycji (U68), kopie innych relacji ukryte i policzone, wybor idzie do --target"
else
    bad "new-relation: Przegladaj = drzewo" "$NROUT" "$(cat "$NR/tree-spec.last" 2>/dev/null | cut -c1-400)"
fi

# Kampania 2026-10-22: cel kopii lokalnej WEWNATRZ zrodla odrzucony w kroku Dokad (nie dopiero w planie).
NROUT=$(nr_run "0${T}local
0${T}__other__
0${T}hdd/backups/192.168.28.99/hdd/lab/kopie
0${T}
0${T}__other__
0${T}hdd/kopie
0${T}default
0${T}lokalna-hdd-backups-192.168.28.99-hdd-lab
0${T}create
0${T}
" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRRC=$?
if grep -qF 'Cel nakłada się na źródło' "$NR/wt.log" && grep -q -- '--target=hdd/kopie' "$NR/zb.log" && ! grep -q -- 'lab/kopie' "$NR/zb.log"; then
    ok "new-relation: kopia lokalna -- cel wewnatrz zrodla odrzucony od razu w kroku Dokad, drugi cel przechodzi"
else
    bad "new-relation: cel wewnatrz zrodla" "rc=$NRRC" "$(cat "$NR/zb.log")" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | tr '\n' ';')"
fi
# 3h. KOPIA LOKALNA (wlasciciel 2026-10-09): trzecia pozycja w kroku 1. Bez hosta i
#     diagnozy, koszyk z datasetow TEGO hosta (list-datasets bez adresu), bez "Sposobu"
#     (zawsze -R), w ustawieniach bez praw/zamrazania/parowania (U25: tytuly okien bez
#     numerow krokow), komenda = wsad local-backup z --name. Bez okna "Pobieram z hosta".
NROUT=$(nr_run "0${T}local
0${T}__other__
0${T}hdd/kopie
0${T}default
0${T}lokalna-hdd-backups-192.168.28.99-hdd-lab
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRRC=$?
# Tytul i brak 'Sposób:' sprawdza ekran drzewa (tree.log), nie dziennik whiptaila.
if [ "$NRRC" -eq 0 ] && has "$NROUT" "CMD: --source=hdd/backups/192.168.28.99/hdd/lab --target=hdd/kopie --recursive=flat --profile=default --name=lokalna-hdd-backups-192.168.28.99-hdd-lab --exclude-family=__replicate_,vzdump,__migration__ --install --yes " \
   && grep -q '^list-datasets --json --own-snapshots$' "$NR/zb.log" && ! grep -q '^check-source' "$NR/zb.log" \
   && grep -qF 'Co kopiować z' "$NR/tree.log" && ! grep -qF 'Sposób:' "$NR/tree.log" \
   && ! grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | grep -qE ' ~ (grant|quies|man) ~ ' \
   && grep -F 'Dokąd na tym hoście' "$NR/wt.log" | head -1 | grep -qF 'Kopie wylądują pod:  <wybrane>/<dataset źródła>' \
   && grep -F 'Nazwa relacji' "$NR/wt.log" | grep -qF ' ~ lokalna-hdd-backups-192.168.28.99-hdd-lab ~ '; then
    ok "new-relation: kopia lokalna -- bez hosta i diagnozy, datasety tego hosta, zawsze -R, bez praw/parowania, komenda local-backup z --name"
else
    bad "new-relation: kopia lokalna" "rc=$NRRC" "$NROUT" "$(cat "$NR/zb.log")" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | head -12 | tr '\n' ';')"
fi
# 3h'. KOPIA LOKALNA ze zrodla, na ktorym sa juz migawki NASZEJ rodziny (family_snapshots>0 w
#      list-datasets, bez hosta -> list-datasets.json): to samo okno "Migawki naszej rodziny
#      już są na źródle" co przy backupie. chain -> kopia PASYWNA (--passive, bez kroku
#      "Retencja źródła", passive-flat NIE polecany, podsumowanie PASYWNIE:); own -> bez
#      --passive, podsumowanie "kopia robi własne". Kontrola: zrodlo bez rodziny (powyzej, 3h)
#      nie ma okna ani flagi.
NRL="$(mktemp -d)"; cp "$P10"/*.json "$NRL/"
"$PY" - "$NRL/list-datasets.json" <<'PYEOF'
import sys, json, time
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in (d["datasets"] if isinstance(d, dict) else d):
    fam = x.get("name") == "hdd/backups/192.168.28.99/hdd/lab"
    x["family_snapshots"] = 5 if fam else 0
    x["family_newest"] = int(time.time()) - 7200 if fam else 0
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
"$PY" - "$NRL/list-profiles.json" <<'PYEOF'
import sys, json, copy
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
if not any(x.get("name") == "passive-flat" for x in d["profiles"]):
    x = copy.deepcopy(d["profiles"][0]); x["name"] = "passive-flat"; d["profiles"].append(x)
for x in d["profiles"]:
    if x.get("name") == "passive-flat":
        x["hidden"] = "yes"
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
nrl_ans() {   # <chain|own> -> odpowiedzi kreatora kopii lokalnej ze zrodlem z rodzina
    printf '%s' "0${T}local
0${T}$1
0${T}__other__
0${T}hdd/kopie
0${T}default
0${T}lokalna-hdd-backups-192.168.28.99-hdd-lab
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}__done__
1${T}
0${T}create
0${T}
"; }
NRLA=$(nr_run "$(nrl_ans chain)" NR_FIX="$NRL" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRLW="$(cat "$NR/wt.log")"
NRLO=$(nr_run "$(nrl_ans own)" NR_FIX="$NRL" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRLOW="$(cat "$NR/wt.log")"
if has "$NRLA" 'CMD: --source=hdd/backups/192.168.28.99/hdd/lab --target=hdd/kopie ' && has "$NRLA" ' --passive ' \
   && has "$NRLW" 'Migawki naszej rodziny już są na źródle' && has "$NRLW" ' ~ chain ~ ' && has "$NRLW" ' ~ own ~ ' \
   && ! has "$NRLW" '--title ~ Retencja źródła ~' && ! has "$NRLW" '[polecany]' && has "$NRLW" 'PASYWNIE:'; then
    ok "new-relation: kopia lokalna ze zrodla z rodzina, odpowiedz 'chain' -- komenda z --passive, bez okna 'Retencja źródła', passive-flat niepolecany, podsumowanie PASYWNIE:"
else
    bad "new-relation: kopia lokalna chain -> --passive" "$NRLA" "$(printf '%s' "$NRLW" | grep -E 'PASYWNIE|polecany|Retencja' | cut -c1-200)" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | head -12 | tr '\n' ';')"
fi
if has "$NRLO" 'CMD: --source=hdd/backups/192.168.28.99/hdd/lab --target=hdd/kopie ' && ! has "$NRLO" '--passive' \
   && has "$NRLOW" 'WŁASNE MIGAWKI: stare migawki naszej rodziny na źródle to resztki -- kopia robi własne,' && ! has "$NRLOW" 'PASYWNIE:'; then
    ok "new-relation: kopia lokalna ze zrodla z rodzina, odpowiedz 'own' -- bez --passive, podsumowanie WŁASNE MIGAWKI ... kopia robi własne (kontrola 'chain' wyzej)"
else
    bad "new-relation: kopia lokalna own -> bez --passive" "$NRLO" "$(printf '%s' "$NRLOW" | grep -E 'WŁASNE|PASYWNIE' | cut -c1-200)"
fi
rm -rf "$NRL"

# 3i. SAME MIGAWKI (X27 S4, wlasciciel 2026-10-14: "A relacja robiaca tylko migawki w
#     zrodle? Wsad? GUI?"): czwarta pozycja w oknie rodzaju. Kopia lokalna BEZ celu -- bez okna
#     "Dokad", bez ustawien dodatkowych (nazwa -> podsumowanie kreatora -> podsumowanie), komenda = wsad local-backup z --target=
#     (pustym) i --install BEZ --yes: czasownik pusty cel potwierdza wzrokiem, wiec pyta
#     sam w terminalu po WYKONAJ, jak przy wsadzie.
NROUT=$(nr_run "0${T}snap
0${T}default
0${T}migawki-hdd-backups-192.168.28.99-hdd-lab
0${T}create
0${T}
" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRRC=$?
NRSI="$(grep -E -- '^--source=hdd/backups/192.168.28.99/hdd/lab --target= .* --no-copy --install --yes$' "$NR/zb.log")"
if [ "$NRRC" -eq 0 ] && [ -n "$NRSI" ] \
   && printf '%s' "$NRSI" | grep -qF -- ' --name=migawki-hdd-backups-192.168.28.99-hdd-lab ' \
   && printf '%s' "$NRSI" | grep -qF -- ' --recursive=flat ' \
   && ! grep -qF 'Dokąd' "$NR/wt.log" && ! grep -qF 'Ustawienia dodatkowe' "$NR/wt.log" \
   && grep -qF 'Gdzie robić migawki na' "$NR/tree.log" && grep -qF 'Jak długo trzymać migawki?' "$NR/wt.log" \
   && grep -qF 'MIGAWKI LOKALNE' "$NR/wt.log"; then
    ok "new-relation: migawki lokalne -- bez celu i ustawien dodatkowych, komenda local-backup --target= --no-copy --install --yes (bez drugiego pytania po WYKONAJ, wlasciciel 2026-10-19)"
else
    bad "new-relation: same migawki" "rc=$NRRC" "$(cat "$NR/zb.log")" "$(grep -o -e '--title ~ [^~]*' "$NR/wt.log" | head -10 | tr '\n' ';')" "$(cat "$NR/err" | tail -5)"
fi

# 3g. nazwa trzymana przez rekord `removed` jest WOLNA (uwaga 11, 2026-10-08): add-client
#     archiwizuje stary rekord, plan to mowi. Dawniej kreator kazal ja "zwolnic" przez
#     delete-relation, co na pve9b nie przechodzilo. Teraz: bez pytania, bez delete-relation.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE="$NRTK")
# Od 2026-10-29 relacja z drugim hostem nazywa sie jak ten host (pve9b) -- okna nazwy nie ma.
if has "$NROUT" " --name=pve9b " && ! grep -q '^delete-relation' "$NR/zb.log" && ! grep -qF "USUNIĘTA relacja" "$NR/wt.log"; then
    ok "new-relation: nazwa = host po drugiej stronie, bez pytania i bez delete-relation (add-client archiwizuje stary rekord)"
else
    bad "new-relation: nazwa usunietej relacji" "$NROUT" "$(cat "$NR/zb.log")" "$(grep -F 'USUNI' "$NR/wt.log" | cut -c1-300)"
fi
# 3g. OKNO USUWANIA mowi PRAWDE o tym, co sie stalo. Odkad nieudana polowa zrodla
#     ZATRZYMUJE czasownik przed purge (REV-144), rekord ZOSTAJE -- a stare zdanie
#     "USUNIETA Z POZOSTALOSCIAMI" bylo wtedy nieprawda: nazwa nadal zajeta, kopie stoja.
DRD="$NR/drd"; rm -rf "$DRD"; mkdir -p "$DRD"
cat > "$NR/bin/zb-del" <<'EOF'
#!/bin/bash
# plan: zwykly plan czasownika. --yes: polowa zrodla NIE wychodzi -> STOP przed 3/4, rc=1.
if [ "$1" = delete-relation ]; then
    case " $* " in
        *" --yes "*)
            echo ">>> delete-relation: 2/4 source side on 10.0.0.9"
            echo ">>> !!! delete-relation: the source's half did NOT complete. The collector's half is done. On 10.0.0.9, as root:"
            echo ">>> !!! delete-relation: STOPPED before 3/4. The record of '$2' is KEPT so that the"
            exit 1 ;;
        *)  echo "delete-relation '$2' (state=removed, peer=10.0.0.9):"
            echo "  1. collector : skipped -- the record already says 'removed'"
            echo "  2. source    : on 10.0.0.9 (port 22), as root over SSH: deploy.sh --leave=pve10  -- the account and its zfs grants there"
            echo "  3. record    : clean-relationships.sh --purge=$2  -- frees the NAME (it refuses anything still LIVE)"
            echo "  4. copies    : KEPT on this host (tank/b/x) -- pass --destroy-copies to destroy them too"
            echo "plan only. Re-run with --yes to do it. Nothing was changed."
            exit 0 ;;
    esac
fi
exit 9
EOF
chmod +x "$NR/bin/zb-del"
printf '0\t\n0\t\n' > "$DRD/answers"   # checklist: domyslne; potem yesno "WYKONAJ"
DROUT=$( export NR_DIR="$DRD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-del"
         bash "$REPO/tui/delete-relation.sh" nazwa ) 2>"$DRD/err" </dev/null
DRWT="$(cat "$DRD/wt.log")"   # od U66 wynik jest w oknie (--textbox), nie na stdout
if has "$DRWT" "ZATRZYMANE" && has "$DRWT" "Rekord relacji 'nazwa' ZOSTAŁ" && has "$DRWT" "uruchom to samo jeszcze raz" \
   && ! has "$DRWT" "USUNIĘTA Z POZOSTAŁOŚCIAMI" && ! has "$DRWT" "GOTOWE"; then
    ok "okno usuwania: gdy polowa zrodla nie wyszla i czasownik ZATRZYMAL sie przed purge (REV-144), okno mowi 'ZATRZYMANE, rekord ZOSTAL, uruchom to samo jeszcze raz' -- a nie 'usunieta z pozostalosciami'"
else
    bad "okno usuwania: komunikat po zatrzymaniu" "$DROUT" "$(cat "$DRD/err")"
fi

# 3i2 (kampania 2026-10-22): relacja LOKALNA bez kopii -- okno mowilo "Zrodlo (?): bez zmian --
#      a local relationship ..." i "Kopii domyslnie NIE ruszam." przy relacji, ktora kopii nie ma.
cat > "$NR/bin/zb-del3" <<'EOF'
#!/bin/bash
[ "$1" = delete-relation ] || exit 9
case " $* " in *" --yes "*) echo "delete-relation: done"; exit 0 ;; esac
echo "delete-relation '$2' (state=active, peer=):"
echo "  1. collector : remove-client $2  -- config sections and cron lines of THIS relationship"
echo "  2. source    : skipped -- a local relationship -- source and copy are on this host"
echo "  3. record    : clean-relationships.sh --purge=$2  -- frees the NAME (it refuses anything still LIVE)"
echo "  4. copies    : none -- a snaponly relationship copies nothing here; its snapshots on the source are NOT destroyed"
echo "plan only. Re-run with --yes to do it. Nothing was changed."
EOF
chmod +x "$NR/bin/zb-del3"
rm -rf "$DRD"; mkdir -p "$DRD"
printf '1\t\n' > "$DRD/answers"   # checklist: Wstecz -> nic nie zmieniono
( export NR_DIR="$DRD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-del3"
  bash "$REPO/tui/delete-relation.sh" lok ) >/dev/null 2>&1 </dev/null
DR3="$(grep -F -e '--checklist' "$DRD/wt.log" | head -1)"
if [ -n "$DR3" ] && ! has "$DR3" 'Źródło (' && ! has "$DR3" 'local relationship' && ! has "$DR3" 'NIE ruszam' && ! has "$DR3" 'SKASUJ KOPIE'; then
    ok "okno usuwania: relacja lokalna bez kopii -- bez 'Źródło (?)', bez angielskiego powodu, bez 'Kopii NIE ruszam'"
else
    bad "okno usuwania: relacja lokalna bez kopii" "$(printf '%s' "$DR3" | cut -c1-400)"
fi

# 3j. U16 (wlasciciel 2026-10-19): bez roota do zrodla okno NIE proponuje sprzatania zrodla
#     (czasownik stanalby w polowie), mowi, co zrobic tam recznie, i usuwa z --keep-source.
cat > "$NR/bin/zb-del2" <<'EOF'
#!/bin/bash
if [ "$1" = delete-relation ]; then
    printf '%s\n' "$*" >> "$NR_DIR/argv"
    case " $* " in
        *" --yes "*) echo "delete-relation: done"; exit 0 ;;
        *" --keep-source "*) src="  2. source    : skipped -- --keep-source" ;;
        *" --check-source "*) src="  2. source    : NO root SSH to 10.0.0.9 (port 22) from this host -- on 10.0.0.9, as root: cd /root/scripts/zfs-snapshot-all && ./deploy.sh --leave=pve10  (or run this with --keep-source)" ;;
        *) src="  2. source    : on 10.0.0.9 (port 22), as root over SSH: deploy.sh --leave=pve10  -- the account and its zfs grants there" ;;
    esac
    echo "delete-relation '$2' (state=active, peer=10.0.0.9):"
    echo "  1. collector : remove-client $2  -- config sections and cron lines of THIS relationship"
    echo "$src"
    echo "  3. record    : clean-relationships.sh --purge=$2  -- frees the NAME (it refuses anything still LIVE)"
    echo "  4. copies    : KEPT on this host (tank/b/x) -- pass --destroy-copies to destroy them too"
    echo "plan only. Re-run with --yes to do it. Nothing was changed."
    exit 0
fi
exit 9
EOF
chmod +x "$NR/bin/zb-del2"
rm -rf "$DRD"; mkdir -p "$DRD"
printf '0\trec\n0\t\n' > "$DRD/answers"   # checklist: zostaw 'Zwolnij nazwę'; potem WYKONAJ
DROUT=$( export NR_DIR="$DRD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-del2"
         bash "$REPO/tui/delete-relation.sh" nazwa ) 2>"$DRD/err" </dev/null
DRCL="$(grep -F -- '--checklist' "$DRD/wt.log" | head -1)"
if ! has "$DRCL" 'Posprzątaj na źródle' && has "$DRCL" 'brak dostępu roota z tego hosta' \
   && has "$DRCL" 'cd /root/scripts/zfs-snapshot-all && ./deploy.sh --leave=pve10' \
   && grep -q -- '--check-source' "$DRD/argv" && grep -q -- 'nazwa --keep-source --yes' "$DRD/argv" \
   && grep -qF 'Na nazwa zostało konto relacji' "$DRD/wt.log"; then
    ok "okno usuwania: bez roota do zrodla -- bez pozycji 'Posprzątaj na źródle', z poleceniem do recznego sprzatania, usuniecie z --keep-source i przypomnienie na koncu (U16)"
else
    bad "okno usuwania: brak roota do zrodla" "cl: $(printf '%s' "$DRCL" | cut -c1-300)" "argv: $(cat "$DRD/argv" 2>/dev/null)" "$DROUT"
fi

# 3j2. Kasowanie kopii ma DRUGIE pytanie "SKASUJ KOPIE -- nieodwracalne" (wlasciciel
#      2026-10-29, #993: jedno "na pewno?" wszedzie, drugie tylko tu). Wstecz w nim nie
#      kasuje niczego; SKASUJ = --destroy-copies --yes; bez kopii do skasowania okna nie ma.
# zb-del4 = zb-del2 z rootem do zrodla (--check-source nie mowi "NO root"): pozycja kopii jest.
grep -vF -e '*" --check-source "*)' "$NR/bin/zb-del2" > "$NR/bin/zb-del4"; chmod +x "$NR/bin/zb-del4"
drd_run() {   # <odpowiedzi> -> $DRD/wt.log, $DRD/argv
    rm -rf "$DRD"; mkdir -p "$DRD"; printf '%b' "$1" > "$DRD/answers"
    ( export NR_DIR="$DRD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-del4"
      bash "$REPO/tui/delete-relation.sh" nazwa ) >/dev/null 2>&1 </dev/null
}
drd_run '0\tsrc|rec|data\n0\t\n1\t\n1\t\n'   # zaznacz kopie, WYKONAJ, SKASUJ? -> Wstecz, potem Wstecz
dk_back_win=$(grep -cF 'SKASUJ KOPIE -- nieodwracalne' "$DRD/wt.log"); dk_back_yes=$(grep -c -- '--yes' "$DRD/argv")
drd_run '0\tsrc|rec|data\n0\t\n0\t\n'        # zaznacz kopie, WYKONAJ, SKASUJ
dk_yes=$(grep -c -- 'nazwa --destroy-copies --yes' "$DRD/argv"); dk_txt=$(grep -A3 -F 'SKASUJ KOPIE -- nieodwracalne' "$DRD/wt.log" | grep -c 'tank/b/x')
drd_run '0\tsrc|rec\n0\t\n'                  # bez kopii: WYKONAJ i od razu bieg
dk_ctl_win=$(grep -cF 'SKASUJ KOPIE -- nieodwracalne' "$DRD/wt.log"); dk_ctl_yes=$(grep -c -- '^delete-relation nazwa --yes' "$DRD/argv")
if [ "$dk_back_win" = 1 ] && [ "$dk_back_yes" = 0 ] && [ "$dk_yes" = 1 ] && [ "$dk_txt" -ge 1 ] \
   && [ "$dk_ctl_win" = 0 ] && [ "$dk_ctl_yes" = 1 ]; then
    ok "okno usuwania: kasowanie kopii pyta drugi raz (SKASUJ KOPIE, z lista kopii); Wstecz tam nie kasuje, SKASUJ = --destroy-copies --yes; bez kopii drugiego okna nie ma"
else
    bad "okno usuwania: drugie pytanie przy kasowaniu kopii" "wstecz: okno=$dk_back_win yes=$dk_back_yes" "skasuj: $dk_yes lista=$dk_txt" "kontrola: okno=$dk_ctl_win yes=$dk_ctl_yes"
fi

# 3j3. U116 (pve10, 2026-10-29): uwaga tabeli retencji zrodla (tui/grid.py) dluzsza niz okno
#      ucinala sie na "(baza kopii to inne szczebl". Teraz zawija sie po slowach w ramce.
GS="$(mktemp)"
cat > "$GS" <<'EOF'
{"title": "Retencja: W ŹRÓDLE KOPII", "head": ["SZCZEBEL", "TUTAJ (cel)", "U ŹRÓDŁA"],
 "rows": [{"key": "0", "label": "godzinowe", "on": true, "value": "24", "unit": "", "ref": "24", "q": null, "family": null, "zero_ok": true}],
 "note": ["Bez zmian = źródło jak cel. Kratka = szczebel u źródła w ogóle.",
          "0 = po skopiowaniu nic z tego szczebla u źródła (baza kopii to inne szczeble)."]}
EOF
GO="$(PYTHONIOENCODING=utf-8 "$PY" "$REPO/tui/grid.py" --spec "$GS" --out "$GS.out" --keys esc --width 80 2>&1 | tr -d '\r')"
# szerokosc w ZNAKACH (ramka to znaki wielobajtowe): kazda linia jak gorna krawedz
glong=$(printf '%s\n' "$GO" | "$PY" -c 'import io, sys
l = [x.rstrip("\n") for x in io.open(sys.stdin.fileno(), encoding="utf-8")]
print(sum(1 for x in l if x and len(x) != len(l[0])))' | tr -d '\r')
if has "$GO" 'szczeble).' && [ "$glong" = 0 ] && printf '%s\n' "$GO" | grep -q '^│ 0 = po skopiowaniu'; then
    ok "tabela retencji: uwaga dluzsza niz okno zawija sie po slowach w ramce, nie ucina sie (U116)"
else
    bad "tabela retencji: dluga uwaga" "linie innej szerokosci: $glong" "$GO"
fi
rm -f "$GS" "$GS.out"

# 3k. F10 USTAWIENIA (wlasciciel 2026-10-19): lista kluczy z `settings --tsv` w sekcjach,
#     zmiana jednej wartosci, "Zapisz" = plan czasownika i WYKONAJ -> `settings set K=V --yes`.
cat > "$NR/bin/zb-set" <<'EOF'
#!/bin/bash
[ "$1" = settings ] || exit 9
case "$2" in
    --tsv) printf 'gui.language\ten\tdefault\tenum:en,pl\tjęzyk okien GUI\n'
           printf 'alerts.email\troot\tzfs-alert.conf\temail\tkto dostaje maile\n'
           printf 'alerts.digest_time\t07:00\tdefault\ttime\to której wychodzi dzienny mail\n'; exit 0 ;;
    set) printf '%s\n' "$*" >> "$NR_DIR/argv"
         case " $* " in *" --yes "*) echo "settings: zapisane i zastosowane."; exit 0 ;; esac
         echo "  alerts.digest_time       07:00 -> 06:30"; echo "plan only. Re-run with --yes to do it. Nothing was changed."; exit 0 ;;
esac
exit 9
EOF
chmod +x "$NR/bin/zb-set"
SD="$NR/sd"; rm -rf "$SD"; mkdir -p "$SD"
printf '0\talerts.digest_time\n0\t06:30\n0\tzapisz\n0\t\n' > "$SD/answers"
SOUT=$( export NR_DIR="$SD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-set"
        bash "$REPO/tui/settings.sh" ) 2>"$SD/err" </dev/null
SMENU="$(grep -F -- '--menu' "$SD/wt.log" | head -1)"
# Prawdziwy whiptail odrzuca znacznik pozycji zaczynający się od '-' jako nieznaną opcję i
# okno znika (pve10, 2026-10-19 -- atrapa tego nie robiła): żaden znacznik nie może tak wyglądać.
if has "$SMENU" '── Alerty ──' && has "$SMENU" '── GUI ──' && has "$SMENU" 'root  (zfs-alert.conf)' && has "$SMENU" 'Wyślij mail próbny' \
   && ! printf '%s' "$SMENU" | grep -qE ' ~ -[^ ~]* ~ ── ' \
   && grep -qx 'settings set alerts.digest_time=06:30' "$SD/argv" && grep -qx 'settings set alerts.digest_time=06:30 --yes' "$SD/argv" \
   && [ "$(printf '%s\n' "$SOUT" | grep -cx 'Zapisano\.')" -eq 1 ] && ! grep -qF 'Zapisano.' "$SD/wt.log"; then   # 2026-10-29: jednozdaniowy sukces = wt_end na stdout, bez msgboxa
    ok "F10 okno ustawien: sekcje i zrodla wartosci z czasownika, zmiana jednej pozycji, Zapisz = plan i WYKONAJ (settings set K=V --yes), 'Zapisano.' na ekranie (wt_end), bez okna"
else
    bad "F10 okno ustawien" "menu: $(printf '%s' "$SMENU" | cut -c1-300)" "argv: $(cat "$SD/argv" 2>/dev/null)" "$SOUT" "$(cut -c1-200 "$SD/err")"
fi

# U53 + U54 (wlasciciel, A.4 2026-10-21): sekcje oddzielone pusta linia, opis klucza jako trzecia
# kolumna; szablon nowej relacji (rodzaj "profile") = wybor z LISTY szablonow, bez ukrytych i
# pochodnych (-src-), kursor na obecnym -- nie pole do wpisania.
cat > "$NR/bin/zb-set2" <<'EOF'
#!/bin/bash
if [ "$1" = list-profiles ]; then
    echo '{"profiles":[{"name":"d7h24","source":"package","description":"7 dobowych + 24 godzinowe"},{"name":"default","source":"package","description":"fabryczny: 12 miesiecy"},{"name":"relacja-x","source":"user","hidden":true,"description":"ukryty"},{"name":"d7h24-src-H24D3","source":"user","description":"pochodny"},{"name":"moj","source":"user","description":"moj szablon"}]}'
    exit 0
fi
[ "$1" = settings ] || exit 9
case "$2" in
    --tsv) printf 'alerts.email\troot\tzfs-alert.conf\temail\tkto dostaje maile\n'
           printf 'new_relation.template\tdefault\tdefault\tprofile\tszablon proponowany nowej relacji\n'; exit 0 ;;
    set) printf '%s\n' "$*" >> "$NR_DIR/argv"
         case " $* " in *" --yes "*) echo "settings: zapisane."; exit 0 ;; esac
         echo "plan only. Nothing was changed."; exit 0 ;;
esac
exit 9
EOF
chmod +x "$NR/bin/zb-set2"
SD="$NR/sd2"; rm -rf "$SD"; mkdir -p "$SD"
printf '0\tnew_relation.template\n0\td7h24\n0\tzapisz\n0\t\n' > "$SD/answers"
SOUT=$( export NR_DIR="$SD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-set2"
        bash "$REPO/tui/settings.sh" ) 2>"$SD/err" </dev/null
SMENU="$(grep -F -- '--menu' "$SD/wt.log" | head -1)"
SPROF="$(grep -F -- '--title ~ new_relation.template ~' "$SD/wt.log" | head -1)"
if has "$SMENU" ' ~ #_new_relation ~   ~ ' && hasE "$SMENU" 'email +root  \(zfs-alert.conf\) +kto dostaje maile' \
   && has "$SPROF" '--menu' && has "$SPROF" '--default-item ~ default ~' && has "$SPROF" ' ~ d7h24 ~ ' && has "$SPROF" ' ~ moj ~ ' \
   && ! has "$SPROF" 'relacja-x' && ! has "$SPROF" 'src-H24D3' && ! has "$SPROF" '--inputbox' \
   && grep -qx 'settings set new_relation.template=d7h24 --yes' "$SD/argv"; then
    ok "F10 U53/U54: sekcje oddzielone, kolumna opisu; szablon nowej relacji z listy (bez ukrytych i -src-), kursor na obecnym, zapis settings set"
else
    bad "F10 U53/U54" "menu: $(printf '%s' "$SMENU" | cut -c1-400)" "prof: $(printf '%s' "$SPROF" | cut -c1-400)" "argv: $(cat "$SD/argv" 2>/dev/null)" "$(cut -c1-200 "$SD/err")"
fi

# U120: opis klucza to trzecia kolumna po kluczu (16) i wartosci (26); limit 100 kolumn z wt-lib
# ucinal go w pol slowa. Okno ustawien bierze pelna szerokosc terminala (do 160).
cat > "$NR/bin/zb-set3" <<'EOF'
#!/bin/bash
[ "$1" = settings ] || exit 9
case "$2" in
    --tsv) printf 'capacity.guard\toff\tdefault\tenum:on,off\tpowyżej progu kasuje najstarsze migawki rodzin z jawnego wzorca retencji KONIEC\n'; exit 0 ;;
esac
exit 9
EOF
chmod +x "$NR/bin/zb-set3"
SD="$NR/sd3"; rm -rf "$SD"; mkdir -p "$SD/bin"
printf '1\t\n' > "$SD/answers"
# Terminal 150x40 przez atrape tput: COLUMNS/LINES nie wystarcza -- tput na runnerze CI (bez
# terminala) ich nie czyta i dawal 80x24 (#967).
printf '#!/bin/bash\ncase "$1" in cols) echo 150 ;; lines) echo 40 ;; *) exit 1 ;; esac\n' > "$SD/bin/tput"; chmod +x "$SD/bin/tput"
SOUT=$( export NR_DIR="$SD" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb-set3" PATH="$SD/bin:$PATH"
        bash "$REPO/tui/settings.sh" ) 2>"$SD/err" </dev/null
SMENU="$(grep -F -- '--menu' "$SD/wt.log" | head -1)"
if has "$SMENU" 'jawnego wzorca retencji KONIEC' && has "$SMENU" ' ~ 146 ~ '; then
    ok "F10 U120: przy 150 kolumnach okno ma 146, opis klucza nie jest uciety"
else
    bad "F10 U120: szerokosc okna ustawien" "menu: $(printf '%s' "$SMENU" | cut -c1-400)" "$(cut -c1-200 "$SD/err")"
fi

# 3i. KROK 9 TO CHECKLISTA, NIE EDYTOR Z WIERSZEM-WYJSCIEM.
#
# Wlasciciel, 2026-09-20, po zobaczeniu ekranu na zywo: "krok 9/10 nie przechodzi
# dalej -- mozna tylko dac wstecz lub wejsc do podswietlonej pozycji", a o wierszu
# "Bez zmian, dalej": "to jest potworek. Ma byc przycisk Dalej, wstecz a wybiera
# sie enterem na liscie". Whiptail (newt 0.52.23) ma DWA przyciski, wiec ekran,
# ktory jednoczesnie edytuje pozycje i ma Dalej, jest niewykonalny -- stad
# checklista: spacja przelacza, Enter = Dalej. ZADNA pozycja listy nie moze byc
# pseudo-akcja "dalej".
NRL="$(grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
if has "$NRL" '--checklist' && has "$NRL" -- '--ok-button ~ Dalej ~' && has "$NRL" -- '--cancel-button ~ Wstecz ~' \
   && ! has "$NRL" 'Bez zmian' && ! has "$NRL" 'DALEJ --' && has "$NRL" 'Ustawienia dodatkowe   [Spacja przełącza] ~' && ! has "$NRL" 'SPACJA' && ! has "$NRL" 'ENTER ='; then
    ok "new-relation: 'Ustawienia dodatkowe' to CHECKLISTA z przyciskami Dalej/Wstecz -- zadna pozycja listy nie udaje przycisku 'dalej' (wlasciciel, 2026-09-20)"
else
    bad "new-relation: ksztalt kroku 9" "$(printf '%s' "$NRL" | cut -c1-400)"
fi
# ...i to samo dla KAZDEGO okna z lista w kreatorze: przycisk zatwierdzenia nazywa
# sie "Dalej" (albo nazywa AKCJE, jak "Usun zaznaczone"), nigdy "Wybierz" -- bo
# lista JEST odpowiedzia i Enter na pozycji ma isc dalej.
# (Od P2 tłumaczenia przycisk to "$(T Dalej)" -- obie formy liczą się tak samo.)
if [ "$(grep -cE -- '--ok-button "(Wybierz|\$\(T Wybierz\))"' "$REPO/tui/new-relation.sh")" -eq 0 ] \
   && [ "$(grep -cE -- '--ok-button "(Dalej|\$\(T Dalej\))"' "$REPO/tui/new-relation.sh")" -ge 6 ]; then
    ok "new-relation: w zadnym oknie przycisk zatwierdzenia nie nazywa sie juz 'Wybierz' -- lista jest odpowiedzia, wiec przycisk to 'Dalej'"
else
    bad "new-relation: przyciski list" "$(grep -n -- '--ok-button' "$REPO/tui/new-relation.sh" | cut -c1-120)"
fi

# 3h. KONTO MA KSZTALT, nie caly kolektor (przeprojektowane po pve11, 2026-09-23:
#     synchro na koncie root chowala szablony-drabiny takze kontu zfsbackup).
#     Krok 6 nie filtruje juz nic; niedopasowanie sprawdza sie PO wyborze konta
#     w kroku 8. NR_FLAT=1: KAZDA zywa relacja (wszystkie na koncie root, bo
#     status.json fikstury nie ma pola local_user) ma szablon plaski.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}
0${T}zfsbackup
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_FLAT=1 NR_TREE="$NRTK")
if has "$NROUT" " --profile=default " && has "$NROUT" " --local-user=zfsbackup " \
   && grep -qF 'Szablon nie pasuje do konta' "$NR/wt.log" && [ "$(grep -cF 'Szablon nie pasuje do konta' "$NR/wt.log")" -eq 1 ] \
   && [ "$(grep -cF -- 'Na jakim koncie mają chodzić zadania' "$NR/wt.log")" -eq 2 ]; then
    ok "new-relation: konto root uzywa juz szablonu plaskiego (config root) -> wybor konta root ze szablonem-drabina (default) pokazuje 'Szablon nie pasuje do konta' i wraca do kroku 8; konto zfsbackup (inny config) przyjmuje ta sama drabine"
else
    bad "new-relation: niedopasowanie szablonu do konta" "$NROUT" "$(grep -F 'Szablon nie pasuje' "$NR/wt.log" | cut -c1-400)" "$(cat "$NR/err")"
fi
# 3f. 'Zatwierdze sam na zrodle': instalacja MA stanac -- to nie awaria, tylko dwa kroki do zrobienia
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE="$NRTK"); NRRC=$?
# U66 czesc 2: wynik jest w OKNIE (textbox -> dziennik atrapy), nie na czarnym ekranie.
if [ "$NRRC" -eq 1 ] && grep -qF "ZATRZYMANE ZGODNIE Z WYBOREM" "$NR/wt.log" && grep -qF "deploy.sh --commit-scope=pve10" "$NR/wt.log" \
   && ! grep -qF "NIE UDAŁO SIĘ" "$NR/wt.log" && ! has "$NROUT" "ZATRZYMANE" \
   && has "$NROUT" "CMD: " && ! has "$(printf '%s' "$NROUT" | grep '^CMD: ')" "--grant-remotely" && grep -q -- "--install --yes" "$NR/new-relation-pve9b.cmd"; then
    ok "new-relation: 'Zatwierdze sam' -> komenda BEZ --grant-remotely, instalacja staje i kreator mowi 'ZATRZYMANE ZGODNIE Z WYBOREM' z dwoma krokami (nie 'NIE UDALO SIE'); komenda do ponowienia zapisana w pliku"
else
    bad "new-relation: zatwierdze sam" "rc=$NRRC" "$NROUT" "$(ls "$NR")"
fi
# A. TSV PLACEHOLDER (wlasciciel, uwaga 11): relacja SYNCHRO ma pusty client_target;
#    IFS=$'\t' read ZLEPIA sasiadujace puste pole z nastepnym (TAB jest biala spacja
#    w IFS), wiec stan 'active' zsuwal sie do zmiennej celu i krok 5 oferowal 'active'
#    jako dataset docelowy -- zywe na pve11.
cat > "$NR/status-empty-target.json" <<'EOF'
{"relations":[{"name":"synchro-empty","state":"active","peer_host":"10.9.9.9","client_target":"","profile":"default","local_user":""}]}
EOF
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
${NRT}" NR_STATUS="$NR/status-empty-target.json" NR_TREE="$NRTK"); NRRC=$?
NRTGT="$(grep -F -- 'Dokąd na tym hoście' "$NR/wt.log" | head -1)"
if [ "$NRRC" -eq 0 ] && ! hasE "$NRTGT" ' ~ active ~ '; then
    ok "new-relation: relacja synchro z PUSTYM client_target nie wypycha 'active' na liste celow w kroku 5 (owner note 11: puste pole staje sie '-', nie zlepia sie z nastepnym)"
else
    bad "new-relation: 'active' jako cel w kroku 5" "$NROUT" "$NRTGT"
fi

# D. POMIJANE MIGAWKI PO PREFIKSACH (wlasciciel, uwagi 10+13): zamiast pola tekstowego
#    (latwo zgubic przecinek -- "__migration___tmp") edytor list_editor (decyzja 2026-10-11:
#    zadnych checklist do dodawania/usuwania); usuniecie vzdump i dodanie _tmp w JEDNYM przebiegu.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}
0${T}__del__
0${T}i:1
0${T}__add__
0${T}_tmp
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE="$NRTK")
if has "$NROUT" " --exclude-family=__replicate_,__migration__,_tmp " && grep -qF 'Pomijane prefiksy' "$NR/wt.log" \
   && grep -qF 'Nowy prefiks' "$NR/wt.log"; then
    ok "new-relation: edytor prefiksow -- 'Usun prefiks' zdejmuje vzdump, 'Dodaj prefiks' dopisuje _tmp, wynik w --exclude-family"
else
    bad "new-relation: edytor pomijanych migawek" "$NROUT" "$(grep -F 'prefiks' "$NR/wt.log" | cut -c1-300)"
fi
# R2-1 (wlasciciel, 2026-09-24): okno pokazywalo PUSTE wiersze -- znacznik (schowany przez
# --notags) byl prefiksem, a opis pusty. Test wyzej sprawdzal tylko WYNIK; ten sprawdza,
# co WIDZI operator: kazdy prefiks stoi w tekscie okna, a kursor startuje na 'Gotowe'.
NRPFX="$(grep -F 'Pomijane prefiksy' "$NR/wt.log" | head -1)"
if has "$NRPFX" '  vzdump' && has "$NRPFX" '  __replicate_' && has "$NRPFX" '  __migration__' && has "$NRPFX" '--default-item ~ __done__ ~' \
   && ! has "$NRPFX" '--checklist'; then
    ok "new-relation: edytor prefiksow POKAZUJE nazwy prefiksow w tekscie, kursor na 'Gotowe' (R2-1: puste wiersze na pve11)"
else
    bad "new-relation: edytor prefiksow -- puste wiersze" "$(printf '%s' "$NRPFX" | cut -c1-400)"
fi
# R2-2: okno planu zaczyna sie od komendy, ktora sie WYKONA, i decyzji po polsku.
# tresc okna ma wiele linii, a atrapa loguje ja doslownie -- bierzemy CALE okno: od jego
# linii tytulowej do nastepnego wywolania (linia zaczynajaca sie od "--").
NRPLAN="$(awk '/Plan ~ --yes-button ~ WYKONAJ/{f=1; buf=""} f && /^--/ && !/Plan ~ --yes-button ~ WYKONAJ/{f=0} f{buf=buf $0 "\n"} END{printf "%s", buf}' "$NR/wt.log")"
# Od 2026-10-29 jedno okno: podsumowanie z komendą + ścieżka pełnego planu (właściciel).
if has "$NRPLAN" 'Komenda (to samo wpisałbyś z palca):' && has "$NRPLAN" '--exclude-family=__replicate_,__migration__,_tmp' \
   && has "$NRPLAN" 'Pomijane migawki z prefiksami: __replicate_, __migration__, _tmp.' \
   && has "$NRPLAN" 'Konto: ' && has "$NRPLAN" 'Pełny plan (sekcje configu, linie crona): ' && ! has "$NRPLAN" 'grant-remotely is noted'; then
    ok "new-relation: okno planu pokazuje komende po WYKONAJ i decyzje po polsku, bez mylacego 'grant-remotely is noted' (R2-2)"
else
    bad "new-relation: okno planu (R2-2)" "$(printf '%s' "$NRPLAN" | cut -c1-600)"
fi

# 4. host, z ktorym relacja JEST: odmowa ze slowem dlaczego, potem Wstecz (U25: z pola hosta
#    na karte), Wyjdz z karty
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.99
0${T}
1${T}
1${T}
"); NRRC=$?
if [ "$NRRC" -eq 1 ] && has "$NROUT" "przerwane, nic nie zmieniono" && grep -F 'Ta relacja już istnieje' "$NR/wt.log" | grep -qF 'lab-ct201' \
   && ! grep -F 'Ta relacja już istnieje' "$NR/wt.log" | grep -qF ': 192.168.28.99,' && ! grep -q '^check-source' "$NR/zb.log"; then
    ok "new-relation: host z istniejaca relacja = odmowa z nazwami relacji (rekord 'removed' sie nie liczy), bez sondy SSH; Wstecz z pola hosta -> karta, Wyjdz z karty = wyjscie rc=1"
else
    bad "new-relation: istniejaca relacja" "rc=$NRRC" "$NROUT" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log")"
fi
# 5. brak pakietu: pytanie -> prepare-source --yes -> ponowna sonda -> dalej
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}
${NRT}" NR_CHECK=check-source.json NR_TREE="$NRTK")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/test-kreator --target" && grep -q '^prepare-source 192.168.28.98 --yes$' "$NR/zb.log" \
   && [ "$(grep -c '^check-source' "$NR/zb.log")" -eq 2 ] && grep -F -- '--yesno' "$NR/wt.log" | grep -qF 'Brak pakietu na źródle' && grep -qF 'Źródło gotowe' "$NR/wt.log"; then
    ok "new-relation: brak pakietu -> pytanie wprost -> prepare-source --yes -> DRUGA sonda pokazuje 'Zrodlo gotowe' -> datasety"
else
    bad "new-relation: instalacja pakietu" "$NROUT" "$(cat "$NR/zb.log")" "$(cat "$NR/wt.log")"
fi
# 6. brak pakietu, odmowa: NIC nie jest instalowane, wraca do pytania o host
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
1${T}
1${T}
1${T}
" NR_CHECK=check-source.json); NRRC=$?
if [ "$NRRC" -eq 1 ] && ! grep -q '^prepare-source' "$NR/zb.log" && [ "$(grep -c 'Z którego hosta' "$NR/wt.log")" -ge 2 ] && ! grep -q '^list-datasets' "$NR/zb.log"; then
    ok "new-relation: 'Wstecz' na pytaniu o instalacje = prepare-source NIE wolany, powrot do adresu hosta, listy datasetow nikt nie pobiera"
else
    bad "new-relation: odmowa instalacji" "rc=$NRRC" "$(cat "$NR/zb.log")" "$(cat "$NR/wt.log")"
fi
# 7. zly adres nie dochodzi do zadnego czasownika
NROUT=$(nr_run "0${T}backup
0${T}pve9b;reboot
0${T}
1${T}
1${T}
")
if grep -qF 'Zły adres' "$NR/wt.log" && ! grep -q 'reboot' "$NR/zb.log"; then
    ok "new-relation: adres ze znakami powloki = okno 'Zly adres', zaden czasownik go nie dostaje"
else
    bad "new-relation: walidacja adresu" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log" 2>/dev/null)"
fi
# 7b. kampania 3 (2026-10-22): adres zaczynajacy sie od '-' przechodzil walidacje (myslnik jest
#     dozwolony), a ssh-keyscan/getent wzialby go za opcje -- tez okno 'Zly adres'
NROUT=$(nr_run "0${T}backup
0${T}-oProxyCommand
0${T}
1${T}
1${T}
")
if grep -qF 'Zły adres' "$NR/wt.log" && ! grep -q 'ProxyCommand' "$NR/zb.log"; then
    ok "new-relation: adres zaczynajacy sie od '-' = okno 'Zly adres', zaden czasownik go nie dostaje"
else
    bad "new-relation: adres z '-' na poczatku" "$(cat "$NR/wt.log" | tail -3)" "$(cat "$NR/zb.log" 2>/dev/null)"
fi
# Kampania 2026-10-22: krok 1 i okno konta to MENU, nie radiolista -- w radioliscie Enter bral
# zaznaczona kropke, a nie podswietlona pozycje (strzalka na "Lustro" i Enter = backup).
NRM1="$(grep -F 'Jaka relacja?' "$NR/wt.log" | head -1)"
if has "$NRM1" '--menu' && ! has "$NRM1" '--radiolist' && has "$NRM1" '--default-item ~ backup ~' \
   && ! grep -F 'Na jakim koncie' "$NR/wt.log" | grep -qF -- '--radiolist'; then
    ok "new-relation: krok 1 (rodzaj) i konto to menu z kursorem na obecnym -- Enter na pozycji ja wybiera"
else
    bad "new-relation: krok 1 / konto jako menu" "$(printf '%s' "$NRM1" | cut -c1-300)"
fi
# 8. kazde okno z wyborem ma rozmiar liczbowy i szerokosc <= 100 (nie na sztywno ponad ekran)
if ! grep -E -- '--(checklist|radiolist|inputbox)' "$NR/wt.log" >/dev/null; then
    bad "new-relation: brak okien w dzienniku"
elif "$PY" - "$NR/wt.log" <<'PYEOF'
import sys, re
bad = 0
for l in open(sys.argv[1], encoding="utf-8"):
    a = l.rstrip("\n").split(" ~ ")
    for k in ("--checklist", "--radiolist", "--inputbox", "--msgbox", "--yesno", "--menu"):
        if k in a:
            i = a.index(k); h, w = a[i + 2], a[i + 3]
            if not (h.isdigit() and w.isdigit() and int(w) <= 100 and int(h) >= 7): bad += 1
sys.exit(1 if bad else 0)
PYEOF
then
    ok "new-relation: kazde okno dostaje liczbowa wysokosc i szerokosc <= 100, wyliczone, nie wpisane"
else
    bad "new-relation: geometria okien" "$(cat "$NR/wt.log")"
fi
# 10. DROGA OPERATORA: czasownik, nie plik. zfs-backup.sh new-relation otwiera krok 1.
rm -f "$NR/wt.log" "$NR/wt.n"; printf '1%s\n' "$T" > "$NR/answers"
NROUT=$( NR_DIR="$NR" NR_FIX="$P10" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb" PYTHON="$PY" bash "$REPO/zfs-backup.sh" new-relation 2>&1 ); NRRC=$?
if [ "$NRRC" -ne 0 ] && has "$NROUT" "przerwane, nic nie zmieniono" && grep -qF 'Jaka relacja?' "$NR/wt.log"; then
    ok "new-relation: czasownik zfs-backup.sh new-relation otwiera kreator na pierwszym oknie (Jaka relacja?); Wyjdz = nic nie zmieniono, rc != 0"
else
    bad "new-relation: czasownik" "rc=$NRRC" "$NROUT" "$(cat "$NR/wt.log" 2>/dev/null)"
fi
if ! bash "$REPO/zfs-backup.sh" new-relation --source=x >/dev/null 2>"$NR/err" && grep -qF 'the wizard takes no arguments' "$NR/err"; then
    ok "new-relation: argumenty = odmowa ze wskazaniem wersji wsadowej (kreator nie jest druga skladnia)"
else
    bad "new-relation: argumenty" "$(cat "$NR/err")"
fi
# 9. bez eval: wartosci ze zdalnego hosta sa danymi
if ! grep -nE '(^|[^#])\beval\b' "$NRS" | grep -v '^[0-9]*:#' | grep -q .; then
    ok "new-relation: w kreatorze nie ma eval -- odpowiedzi check-source czytane przez read -r"
else
    bad "new-relation: eval w kreatorze" "$(grep -n 'eval' "$NRS")"
fi

# ============================================================================
# replica: KREATOR REPLIKI NA WHIPTAILU (uwagi 20 i 16+19, 2026-10-08; P5 2026-10-09)
#
# Ta sama atrapa whiptaila co kreator relacji; zb, zpool i zfs to atrapy, ktore tylko
# odpowiadaja i zapisuja wywolania. P5: najpierw RODZAJ nosnika (4/6), potem NOSNIK
# (5/6, tylko podlaczony); dysk pamietany po ID puli (--media-guid); "po wlozeniu" to
# ustawienie repliki (--on-insert), okno B zawsze dla wymiennego z harmonogramem;
# formatowanie: "Sformatuj nowy nosnik" (nowa) / "Dodaj kolejny dysk" (zmiana).
# Krok 2 to wspolny koszyk (tui/basket-lib.sh).
# ============================================================================
RP="$(mktemp -d)"; mkdir -p "$RP/bin"
cp "$NR/bin/whiptail" "$RP/bin/whiptail"
cp "$NR/bin/tree" "$RP/bin/tree"    # okno-drzewo (patrz $NR/bin/tree): stan w $NR_DIR = $RP
cat > "$RP/bin/zb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${NR_DIR:?}/zb.log"
case "$1" in
    list-replicas) if [ -n "${RP_REPS:-}" ]; then printf '%s\n' "$RP_REPS"; else echo '{"replicas":[]}'; fi ;;
    status) echo '{"relations":[{"name":"pve11b","state":"active","managed_datasets":["hdd/backups/192.168.28.96/hdd/vm"]}]}' ;;
    list-datasets) if [ -n "${RP_ENC:-}" ]; then
                       echo '{"datasets":[{"name":"hdd","encryption":"off"},{"name":"hdd/backups","encryption":"off"},{"name":"hdd/backups/192.168.28.96","encryption":"off"},{"name":"hdd/backups/192.168.28.96/hdd/vm","encryption":"aes-256-gcm"},{"name":"hdd/data","encryption":"off"},{"name":"hdd/data/mail","encryption":"off"},{"name":"hdd/data/docs","encryption":"off"}]}'
                   else
                       echo '{"datasets":[{"name":"hdd"},{"name":"hdd/backups"},{"name":"hdd/backups/192.168.28.96"},{"name":"hdd/backups/192.168.28.96/hdd/vm"},{"name":"hdd/data"},{"name":"hdd/data/mail"},{"name":"hdd/data/docs"}]}'
                   fi ;;
    add-replica) case " $* " in
            *" --plan "*) echo "--- what will change in the crontab (left side = what IS installed now) ---"; echo "  +0 22 * * 5 /x/zfs-job.sh \"h replica copy ($2)\" -- ..."; exit 0 ;;
            *) echo ">>> atrapa: zainstalowano"; exit 0 ;;
        esac ;;
    install-media-trigger) echo ">>> atrapa: regula"; exit 0 ;;
    remove-media-trigger) echo ">>> atrapa: regula zdjeta"; exit 0 ;;
    prepare-media) case " $* " in
            *" --list "*) printf '/dev/disk/by-id/usb-C	2G	QEMU	USB-C	-
'; [ -n "${RP_DISKS:-}" ] && printf '%b' "$RP_DISKS" ;;
            *" --yes "*)  echo ">>> prepare-media: medium ready"; echo "guid=777" ;;
            *)            echo "PLAN (prepare-media):"; echo "  1. zpool create ... EVERYTHING on the disk is erased" ;;
        esac ;;
    *) echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
printf '#!/bin/sh\ncase "$1" in list) echo hdd ;; import) printf "   pool: repl\\n     id: 4242\\n" ;; esac\nexit 0\n' > "$RP/bin/zpool"
printf '#!/bin/sh\necho "zfs $*" >> "$NR_DIR/zb.log"\ncase "$*" in *"-t filesystem,volume"*) printf "hdd\\nhdd/backups\\nhdd/backups/192.168.28.96\\nhdd/backups/192.168.28.96/hdd/vm\\nhdd/data\\n" ;; esac\nexit 0\n' > "$RP/bin/zfs"
chmod +x "$RP/bin/"*
rp_run() {   # <odpowiedzi> [ENV=...] -> stdout kreatora; dzienniki w $RP
    rm -f "$RP/wt.log" "$RP/wt.n" "$RP/zb.log" "$RP/tree.n" "$RP/tree.log" "$RP/treekeys"
    printf '%s' "$1" > "$RP/answers"; shift
    ( export NR_DIR="$RP" WHIPTAIL="$RP/bin/whiptail" ZFS_BACKUP="$RP/bin/zb" PYTHON="$PY" PATH="$RP/bin:$PATH" \
             ZFS_REPLICA_RULES="$RP/rules" "$@"
      # Drzewo wyboru datasetow (tui/tree.py) bez terminala: klawisze z RP_TREE, jedna linia
      # na wywolanie okna, linie rozdzielone '|' (jak odpowiedzi); brak linii = Esc.
      printf '%s\n' "${RP_TREE:-}" | tr '|' '\n' > "$RP/treekeys"
      export TREE_PY="$PY" TREE_REPO="$REPO" ZFS_TREE="$RP/bin/tree"
      bash "$REPO/tui/replica.sh" ${RP_NAME:+"$RP_NAME"} ) 2>"$RP/err" </dev/null
}
# Kampania 3 (2026-10-23): Esc w kroku 1 nowej repliki wychodzil bez pytania. Teraz pyta jak
# kreator relacji; Przerwij konczy bez zmian, Zostan (tez Esc) wraca do kroku 1.
RPOUT=$(rp_run "1${T}
0${T}"); RPRC=$?
rp_q1=$(grep -c 'Nowa replika: przerwać?' "$RP/wt.log" 2>/dev/null)
RPOUT2=$(rp_run "1${T}
1${T}
1${T}
0${T}"); RPRC2=$?
rp_q2=$(grep -c 'Nowa replika: przerwać?' "$RP/wt.log" 2>/dev/null); rp_n2=$(grep -c 'Nowa replika -- 1/6 nazwa' "$RP/wt.log" 2>/dev/null)
if [ "$RPRC" -eq 1 ] && has "$RPOUT" "przerwane, nic nie zmieniono" && [ "$rp_q1" = 1 ]    && [ "$RPRC2" -eq 1 ] && [ "$rp_q2" = 2 ] && [ "$rp_n2" = 2 ] && grep -q -- '--defaultno' "$RP/wt.log"; then
    ok "replika: Esc w kroku 1 pyta 'przerwać?' (domyślnie Zostań); Zostań wraca do nazwy, Przerwij kończy bez zmian"
else
    bad "replika: Esc w kroku 1" "rc=$RPRC/$RPRC2 pytan=$rp_q1/$rp_q2 krok1=$rp_n2" "$RPOUT"
fi
rm -f "$RP/rules"
# H-7 (kampania 2026-10-21): nosnik INNEJ repliki nie jest zrodlem nowej -- staly nosnik = jego
# katalog docelowy z poddrzewem znika z drzewa (wymienny = cala jego pula, ta sama funkcja).
rp_run "0${T}usb2
" RP_TREE='esc' 'RP_REPS={"replicas":[{"name":"stala","sources":["hdd/backups"],"dst":"hdd/data","media":"fixed"}]}' >/dev/null
if grep -qF '] backups' "$RP/tree.log" && ! grep -qF '] data' "$RP/tree.log" && ! grep -qF ' mail' "$RP/tree.log"; then
    ok "replika H-7: nosnik innej repliki (staly: hdd/data z poddrzewem) nie jest na liscie zrodel"
else
    bad "replika H-7: nosnik innej repliki na liscie zrodel" "$(head -12 "$RP/tree.log")"
fi
# Kampania 2026-10-22: wlasny harmonogram sprawdzany W OKNIE -- "0 22 * * *zle" szedl az do planu.
rm -f "$RP/rules"
RPOUT=$(rp_run "0${T}usb2
0${T}passive
0${T}removable
0${T}repl
0${T}__other__
0${T}0 22 * * *zle
0${T}
0${T}61 25 * * *
0${T}
0${T}30 21 * * 1-5
0${T}
0${T}
" RP_TREE='goto:hdd/backups,space,enter'); RPRC=$?
# Kampania pve10 2026-10-29: po bledzie okno wraca DO POLA (bylo: do menu z "auto" -- Enter dawal
# auto po cichu), a "61 25 * * *" (poza zakresem) tez jest odrzucane.
if [ "$(grep -cF 'Zły harmonogram' "$RP/wt.log")" = 2 ] && [ "$(grep -cF 'kiedy kopiować?' "$RP/wt.log")" = 1 ] \
   && grep -q "^add-replica usb2 .*--schedule=30 21 \* \* 1-5 " "$RP/zb.log" && ! grep -q 'zle\|61 25' "$RP/zb.log"; then
    ok "replika: zly wlasny harmonogram (znaki i zakres pol) odrzucony w oknie, ponowny wpis w TYM SAMYM polu, poprawny idzie do planu"
else
    bad "replika: walidacja wlasnego harmonogramu" "rc=$RPRC" "$(cat "$RP/zb.log")" "$(grep -o -e '--title ~ [^~]*' "$RP/wt.log" | tr '\n' ';')"
fi
rm -f "$RP/rules"
# (1)+(2): zrodlo hdd/backups obejmuje kopie relacji pve11b; tydzien; B = Tak; dysk w slocie
#          ma ID 4242 -> --media-guid=4242, --on-insert=yes, regula jako krok planu.
RPOUT=$(rp_run "0${T}usb2
0${T}passive
0${T}removable
0${T}repl
0${T}0 22 * * 5
0${T}
0${T}
" RP_TREE='goto:hdd/backups,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -q '^add-replica usb2 --source=hdd/backups --dst=repl/replica --schedule=0 22 \* \* 5 --removable --recursive=yes --passive --media-guid=4242 --on-insert=yes --install --yes$' "$RP/zb.log" \
   && grep -q '^install-media-trigger --install$' "$RP/zb.log" \
   && grep -F '3/6 migawki' "$RP/wt.log" | grep -qF -- '--default-item ~ passive ~' \
   && grep -F '4/6 rodzaj' "$RP/wt.log" | grep -q . && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'repl  dysk podłączony' \
   && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF -- '--default-item ~ repl ~' \
   && ! grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'Wpisz nazwę puli' \
   && grep -F '6/6 kiedy' "$RP/wt.log" | grep -qF '0 22 * * 5 ~ co tydzień, piątek 22:00' \
   && grep -F 'także po podłączeniu' "$RP/wt.log" | grep -qF 'Uruchamiać kopię także po podłączeniu dysku' \
   && grep -qF 'reguła udev ZOSTANIE ZAŁOŻONA' "$RP/wt.log" && grep -qF 'po ID puli: 4242' "$RP/wt.log" \
   && grep -qF 'Pierwsza kopia ruszy opóźniona po podłączeniu dysku albo o czasie z harmonogramu.' "$RP/wt.log"; then
    ok "replica: rodzaj przed nosnikiem, nosnik z listy (bez wpisywania), ID puli -> --media-guid; B Tak -> --on-insert=yes i regula w planie"
else
    bad "replica: kreator, pasywna + harmonogram + B" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -5 "$RP/wt.log" | cut -c1-300)" "$(cat "$RP/err")"
fi
# (1e) wlasciciel 2026-10-12: pod zrodlem repliki jest kopia ZASZYFROWANA (relacja
#      pobrana raw, kolektor nie ma klucza) -> nowa replika z --raw i zdanie w planie;
#      kontrola (1) wyzej: zrodlo bez szyfrowania -> bez --raw.
RPOUT=$(rp_run "0${T}usb2e
0${T}passive
0${T}removable
0${T}repl
0${T}0 22 * * 5
0${T}
0${T}
" RP_ENC=1 RP_TREE='goto:hdd/backups,space,enter')
if grep -q '^add-replica usb2e .* --passive .*--raw .*--install --yes$' "$RP/zb.log" && grep -qF 'kopia idzie zaszyfrowana (raw)' "$RP/wt.log"; then
    ok "replica: zaszyfrowane zrodlo -> --raw i 'kopia idzie zaszyfrowana' w planie; zwykle zrodlo (1) -- bez --raw"
else
    bad "replica: raw dla zaszyfrowanego zrodla" "$RPOUT" "$(cat "$RP/zb.log")" "$(grep -F 'Szyfrowane' "$RP/wt.log" | head -1 | cut -c1-200)" "$(cat "$RP/err")"
fi
# (3): "tylko po wlozeniu" nie pyta o B, regula i tak zakladana; bez --on-insert w komendzie
RPOUT=$(rp_run "0${T}usb3
0${T}own
0${T}mirror
0${T}removable
0${T}repl
0${T}on-insert
0${T}
0${T}
" RP_TREE='goto:hdd/data,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -q '^add-replica usb3 --source=hdd/data --dst=repl/replica --schedule=on-insert --removable --recursive=yes --media-guid=4242 --install --yes$' "$RP/zb.log" \
   && grep -F '3/6 migawki' "$RP/wt.log" | grep -qF -- '--default-item ~ own ~' \
   && ! grep -qF 'także po podłączeniu' "$RP/wt.log" && grep -q '^install-media-trigger --install$' "$RP/zb.log" \
   && grep -qF 'Pierwsza kopia ruszy opóźniona po podłączeniu dysku.' "$RP/wt.log"; then
    ok "replica: oryginal -> domyslnie wlasne migawki; 'tylko po wlozeniu' nie pyta o B, regula i tak zakladana"
else
    bad "replica: kreator, on-insert" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -5 "$RP/wt.log" | cut -c1-300)"
fi
# (4): regula (z --on-insert) juz jest -> okno B JEST (to ustawienie repliki); Nie =
#      --on-insert=no, bez zakladania reguly, plan mowi "tylko wg harmonogramu". Zadna
#      replika nie rusza juz po wlozeniu -> plan ZDEJMUJE regule (wlasciciel 2026-10-18:
#      "skoro mozemy wlaczac, chcemy moc wylaczyc").
printf '# Managed by zfs-backup.sh install-media-trigger\nRUN+="x run-replicas --on-insert --config=y"\n' > "$RP/rules"
RPOUT=$(rp_run "0${T}usb4
0${T}own
0${T}mirror
0${T}removable
0${T}repl
0${T}0 22 * * *
1${T}
0${T}
" RP_TREE='goto:hdd/data,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -qF 'także po podłączeniu' "$RP/wt.log" && ! grep -q '^install-media-trigger' "$RP/zb.log" \
   && grep -q -- '--on-insert=no --install --yes$' "$RP/zb.log" && grep -qF 'Po podłączeniu: nic -- kopia tylko wg harmonogramu' "$RP/wt.log" \
   && grep -qF 'ZOSTANIE ZDJĘTA' "$RP/wt.log" && grep -q '^remove-media-trigger --install$' "$RP/zb.log"; then
    ok "replica: okno B zawsze (ustawienie repliki, nie hosta) -- Nie = --on-insert=no; zadna replika nie rusza po wlozeniu -> plan zdejmuje regule"
else
    bad "replica: kreator, B przy istniejacej regule" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-300)"
fi
# Wlasciciel 2026-10-23 (jedna replika na godzine): nowa replika domyslnie "codziennie w nocy,
# o wolnej godzinie" -- kreator podaje --schedule=auto, godzine wybiera add-replica.
RPOUT=$(rp_run "0${T}usb5
0${T}own
0${T}mirror
0${T}removable
0${T}repl
0${T}auto
1${T}
0${T}
" RP_TREE='goto:hdd/data,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -q -- '--schedule=auto' "$RP/zb.log" && grep -qF 'codziennie w nocy, o wolnej godzinie' "$RP/wt.log" \
   && grep -q -- '--default-item ~ auto' "$RP/wt.log"; then
    ok "replica: domyslny harmonogram nowej repliki to 'w nocy, o wolnej godzinie' -- --schedule=auto"
else
    bad "replica: harmonogram auto" "rc=$RPRC" "$(grep -- '--schedule' "$RP/zb.log" | head -2)" "$(grep -o 'default-item ~ [^~]*' "$RP/wt.log" | head -3)"
fi
# (4b): regula sprzed P5 (run-replicas BEZ --on-insert uruchamiala wszystkie) -> przy Tak
#       plan ja ODNAWIA i install-media-trigger idzie po instalacji.
printf '# Managed by zfs-backup.sh install-media-trigger\nRUN+="x run-replicas --config=y"\n' > "$RP/rules"
RPOUT=$(rp_run "0${T}usb4
0${T}own
0${T}mirror
0${T}removable
0${T}repl
0${T}0 22 * * *
0${T}
0${T}
" RP_TREE='goto:hdd/data,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -qF 'reguła udev ZOSTANIE ODNOWIONA' "$RP/wt.log" && grep -q '^install-media-trigger --install$' "$RP/zb.log"; then
    ok "replica: stara regula (bez --on-insert) jest odnawiana, gdy replika ma ruszac po wlozeniu"
else
    bad "replica: odnowienie reguly" "rc=$RPRC" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-300)"
fi
# (5) "Sformatuj nowy nosnik" (uwaga 7): bez pytan o nazwe i baze -- pula <host>-<replika>,
#     baza replica; plan z przyciskiem "Sformatuj (KASUJE dysk)" i --defaultno; ID z
#     prepare-media trafia do --media-guid.
rm -f "$RP/rules"
RPOUT=$(rp_run "0${T}usb5
0${T}own
0${T}mirror
0${T}removable
0${T}__prep__
0${T}/dev/disk/by-id/usb-C
0${T}
0${T}
0${T}0 22 * * *
1${T}
0${T}
" RP_TREE='goto:hdd/data,space,enter'); RPRC=$?
if [ "$RPRC" -eq 0 ] && grep -q '^prepare-media --list$' "$RP/zb.log" \
   && grep -qE '^prepare-media [A-Za-z0-9._-]+-usb5 /dev/disk/by-id/usb-C --base=replica --encrypt --yes$' "$RP/zb.log" \
   && grep -F 'szyfrowanie' "$RP/wt.log" | grep -qF 'Szyfrować nośnik?' \
   && grep -qE '^add-replica usb5 --source=hdd/data --dst=[A-Za-z0-9._-]+-usb5/replica .* --media-guid=777 --on-insert=no --install --yes$' "$RP/zb.log" \
   && grep -F 'formatowanie nośnika' "$RP/wt.log" | grep -qF 'Sformatuj (KASUJE dysk)' \
   && grep -F 'formatowanie nośnika' "$RP/wt.log" | grep -qF -- '--defaultno' \
   && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'Sformatuj nowy nośnik' && ! grep -qF 'baza na nośniku' "$RP/wt.log"; then
    ok "replica: 'Sformatuj nowy nosnik' -- bez pytan o nazwe/baze (<host>-<replika>/replica), pytanie o szyfrowanie (Tak = --encrypt, W19b), plan --defaultno, ID do --media-guid"
else
    bad "replica: formatowanie nosnika" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -6 "$RP/wt.log" | cut -c1-250)"
fi
# K27 (kampania pve10, 2026-10-29): dysk z pula INNEJ repliki nie jest na liscie do formatowania
# (jedynym dyskiem na liscie byl nosnik usb9 -- jeden Enter od wyczyszczenia cudzej repliki).
rm -f "$RP/rules"
RPOUT=$(rp_run "0${T}usb6
0${T}own
0${T}mirror
0${T}removable
0${T}__prep__
" RP_TREE='goto:hdd/data,space,enter' 'RP_DISKS=/dev/disk/by-id/usb-D\t4G\tQEMU\tUSB-D\tzfs:sejfpula\n/dev/disk/by-id/usb-E\t4G\tQEMU\tUSB-E\tzfs:staraobca\n' \
  'RP_REPS={"replicas":[{"name":"sejf","sources":["hdd/backups"],"dst":"sejfpula/replica","media":"removable"}]}'); RPRC=$?
RPFM="$(grep -F 'który dysk sformatować' "$RP/wt.log" | head -1)"
if [ -n "$RPFM" ] && has "$RPFM" 'usb-C' && has "$RPFM" 'usb-E' && ! has "$RPFM" 'usb-D'; then
    ok "replica K27: dysk z pula INNEJ repliki (sejfpula) nie jest do formatowania; pusty i z obca pula -- sa (z ostrzezeniem)"
else
    bad "replica K27: lista dyskow do formatowania" "rc=$RPRC" "$(printf '%s' "$RPFM" | cut -c1-400)"
fi
# (6) WYJATKI (uwaga 13): ten sam koszyk co w relacji -- "Wyjatki..." przy hdd/data,
#     odznaczone mail -> --exclude-child=^hdd/data/mail$ w komendzie i "Pomijane" w planie;
#     w koszyku repliki nie ma pozycji "Sposob" (zawsze -R).
rm -f "$RP/rules"
RPOUT=$(rp_run "0${T}usb6
0${T}own
0${T}mirror
0${T}removable
0${T}repl
0${T}0 22 * * *
1${T}
0${T}
" RP_TREE='goto:hdd/data,space,goto:hdd/data/mail,space,enter'); RPRC=$?
# X12: koszyk to drzewo (tree.log): tytul kroku 2/6 i brak 'Sposób:' sprawdza jego ekran, nie whiptail.
if [ "$RPRC" -eq 0 ] && grep -q '^add-replica usb6 --source=hdd/data --dst=repl/replica .*--recursive=yes --exclude-child=^hdd/data/mail\$ .*--install --yes$' "$RP/zb.log" \
   && grep -qF 'Pomijane:   hdd/data/mail' "$RP/wt.log" \
   && grep -F 'Co kopiować z' "$RP/tree.log" | head -1 | grep -qF 'Replika usb6 -- 2/6' \
   && ! grep -qF 'Sposób:' "$RP/tree.log" && grep -qF '[ ] mail' "$RP/tree.log"; then
    ok "replica: koszyk jak w relacji -- wyjatek (odznaczony mail) daje --exclude-child=^hdd/data/mail\$, plan go wymienia, bez pozycji 'Sposob'"
else
    bad "replica: koszyk z wyjatkiem" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(cat "$RP/tree.log" 2>/dev/null)"
fi
# (7) ZMIANA repliki sprzed P5 (bez ID): koszyk z jej zrodel i wyjatkow; obecny dysk
#     w slocie dostaje swoje ID (--media-guid=4242); nie ma "Sformatuj nowy nosnik".
RPOUT=$(rp_run "0${T}zrodla
0${T}nosnik
0${T}removable
0${T}repl
0${T}zapisz
0${T}
" RP_TREE=enter 'RP_REPS={"replicas":[{"name":"usb7","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":["^hdd/data/mail$"],"media_guids":"","on_insert":"no"}]}' RP_NAME=usb7)
if grep -q '^add-replica usb7 --source=hdd/data .*--exclude-child=^hdd/data/mail\$ .*--media-guid=4242 --on-insert=no --install --yes$' "$RP/zb.log" \
   && ! grep -F ': nośnik ~' "$RP/wt.log" | grep -qF 'Sformatuj nowy nośnik' && grep -F ': nośnik ~' "$RP/wt.log" | grep -qF 'Dodaj dysk (podłączony zostanie sformatowany)'; then
    ok "replica: zmiana repliki -- koszyk z jej zrodel i wyjatkow; obecny dysk dostaje ID; zamiast 'Sformatuj nowy' jest 'Dodaj kolejny dysk'"
else
    bad "replica: zmiana -- koszyk i ID" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-250)"
fi
# (8) "Dodaj kolejny dysk do tej repliki": formatuje z TA SAMA pula i baza, bez pytan;
#     ID nowego dysku dopisane do listy (4242,777) -- zaden dysk nie jest wylaczany.
RPOUT=$(rp_run "0${T}nosnik
0${T}removable
0${T}__add__
0${T}/dev/disk/by-id/usb-C
1${T}
0${T}
0${T}
0${T}zapisz
0${T}
" RP_TREE=enter 'RP_REPS={"replicas":[{"name":"usb8","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":[],"media_guids":"4242","on_insert":"no"}]}' RP_NAME=usb8)
if grep -q '^prepare-media repl /dev/disk/by-id/usb-C --base=replica --yes$' "$RP/zb.log" \
   && grep -q '^add-replica usb8 --source=hdd/data --dst=repl/replica .*--media-guid=4242,777 --on-insert=no --install --yes$' "$RP/zb.log"; then
    ok "replica: 'Dodaj kolejny dysk' -- ta sama pula i baza bez pytan, ID dopisane (4242,777), obecny dysk zostaje"
else
    bad "replica: dodaj kolejny dysk" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-250)"
fi
# (9) W12 "Usuń dysk z repliki": dysk 777 wypada z listy (--media-guid=4242), dane
#     zostaja; ostatniego dysku nie da sie usunac (przy jednym ID pozycji nie ma).
RPOUT=$(rp_run "0${T}nosnik
0${T}removable
0${T}__del__
0${T}777
0${T}repl
0${T}zapisz
0${T}
" RP_TREE=enter 'RP_REPS={"replicas":[{"name":"usb9","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":[],"media_guids":"4242,777","on_insert":"no"}]}' RP_NAME=usb9)
RP9="$(grep -F ': nośnik ~' "$RP/wt.log" | head -1)"
if grep -q '^add-replica usb9 .*--media-guid=4242 --on-insert=no --install --yes$' "$RP/zb.log" && has "$RP9" 'Usuń dysk z repliki'; then
    ok "replica: W12 'Usuń dysk z repliki' -- 777 wypada (--media-guid=4242), dane zostaja"
else
    bad "replica: usun dysk" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-250)"
fi
# (10) W11 (pve9b 2026-10-11): replika sprzed zapisu ID (pusta lista) + "Dodaj dysk":
#      najpierw ID obecnego dysku (4242), potem nowego (777) -- stary nie staje sie obcy.
RPOUT=$(rp_run "0${T}nosnik
0${T}removable
0${T}__add__
0${T}/dev/disk/by-id/usb-C
1${T}
0${T}
0${T}
0${T}zapisz
0${T}
" RP_TREE=enter 'RP_REPS={"replicas":[{"name":"usb10","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":[],"media_guids":"","on_insert":"no"}]}' RP_NAME=usb10)
RP10="$(grep -F ': nośnik ~' "$RP/wt.log" | head -1)"
if grep -q '^add-replica usb10 .*--media-guid=4242,777 --on-insert=no --install --yes$' "$RP/zb.log" && ! has "$RP10" 'Usuń dysk z repliki'; then
    ok "replica: W11 'Dodaj dysk' w replice bez zapisanych ID -- obecny dysk (4242) dopisany przed nowym (777); przy jednym dysku nie ma 'Usuń dysk'"
else
    bad "replica: dodaj dysk bez ID" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-250)"
fi
# (11) W18: "Tylko stan na chwile kopii" + "Trzymaj N ostatnich" = --keep=12 (wlasna
#      historia dysku, bez lustra); plan mowi "12 ostatnich kopii".
RPOUT=$(rp_run "0${T}dysk
0${T}own
0${T}keep
0${T}12
0${T}zapisz
0${T}
" RP_TREE=enter 'RP_REPS={"replicas":[{"name":"usb11","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 1 * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":[],"media_guids":"4242","on_insert":"no"}]}' RP_NAME=usb11)
if grep -q '^add-replica usb11 .*--keep=12 .*--install --yes$' "$RP/zb.log" && grep -qF '12 ostatnich kopii' "$RP/wt.log"; then
    ok "replica: W18 'Trzymaj N ostatnich kopii' -> --keep=12, plan mowi o wlasnej historii dysku"
else
    bad "replica: keep N (W18)" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-250)"
fi
# (12) Ustawienia silnika repliki (wlasciciel 2026-10-12): "Zmien replike" -> "Ustawienia
#      silnika" -> Historia: tylko roznica, Na dysku: 6 ostatnich -> plan -> WYKONAJ; reszta
#      repliki (zrodla, nosnik, harmonogram, ID dysku) bez zmian. Kontrola: wczesniej zapisana
#      history przechodzi tez przez zwykly kreator (nie ginie).
RPOUT=$(rp_run "0${T}silnik
0${T}hist
0${T}newest
0${T}disk
0${T}keep
0${T}6
0${T}__done__
0${T}zapisz
0${T}
" 'RP_REPS={"replicas":[{"name":"usb12","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":["^hdd/data/mail$"],"media_guids":"4242","on_insert":"no","history":"all"}]}' RP_NAME=usb12)
RP12="$(grep -F 'Ustawienia silnika: replika usb12' "$RP/wt.log" | head -1)"
# X10 (2026-10-14): wybor "6 ostatnich" kasuje wczesniejsze "tylko roznica" (sprzeczne) --
# do add-replica nie idzie --history, wiersz Historia znika, plan mowi, co naprawde idzie.
RPLAST="$(grep -F 'Ustawienia silnika: replika usb12' "$RP/wt.log" | tail -1)"
if grep -q '^add-replica usb12 --source=hdd/data --dst=repl/replica --schedule=0 22 \* \* \* --removable --recursive=yes --exclude-child=^hdd/data/mail\$ .*--keep=6 --media-guid=4242 --on-insert=no --install --yes$' "$RP/zb.log"    && ! grep -q -- '--history=' "$RP/zb.log" && has "$RP12" 'Historia' && has "$RP12" '(fabryczne)' && ! has "$RP12" 'Kompresja'    && ! has "$RPLAST" 'Historia ' && has "$RPLAST" '6 ostatnich migawek replica_' && grep -qF 'Historia:   tylko najnowsza migawka replica_' "$RP/wt.log"; then
    ok "replica: Ustawienia silnika -- 'na dysku' 6 ostatnich zmienione, reszta bez zmian; X10: przy N ostatnich bez wyboru Historii (sprzeczne), plan mowi co idzie"
else
    bad "replica: ustawienia silnika" "$RPOUT" "$(cat "$RP/zb.log")" "$(printf '%s' "$RP12" | cut -c1-300)" "$(cat "$RP/err")"
fi
# (13) U8 (właściciel 2026-10-18): zmiana repliki = JEDNA LISTA z obecnymi wartościami.
#      "[ ] Po włożeniu dysku" przełącza się od razu (bez okna), "Zapisz zmiany" = plan i
#      WYKONAJ -- żadnego innego kroku kreatora. Brak reguły udev -> plan ją zakłada.
rm -f "$RP/rules"
RPOUT=$(rp_run "0${T}onins
0${T}zapisz
0${T}
" 'RP_REPS={"replicas":[{"name":"usb13","sources":["hdd/data"],"dst":"repl/replica","schedule":"0 22 * * *","media":"removable","recursive":"yes","prefix":"replica_","exclude_child":[],"media_guids":"4242","on_insert":"no"}]}' RP_NAME=usb13)
RP13="$(grep -F 'Zmiana repliki usb13' "$RP/wt.log" | grep -F -e '--menu' | head -1)"
RP13B="$(grep -F 'Zmiana repliki usb13' "$RP/wt.log" | grep -F -e '--menu' | sed -n 2p)"
if grep -q '^add-replica usb13 --source=hdd/data --dst=repl/replica .*--media-guid=4242 --on-insert=yes --install --yes$' "$RP/zb.log" \
   && grep -q '^install-media-trigger --install$' "$RP/zb.log" \
   && has "$RP13" 'nic, tylko wg harmonogramu' && has "$RP13" 'codziennie 22:00' && has "$RP13" 'repl/replica (wymienny)' \
   && has "$RP13" 'replika usb13   kolektor' && has "$RP13" 'Zapisz zmiany (brak zmian)' && ! has "$RP13" '* ' \
   && has "$RP13B" '* Po podłączeniu' && has "$RP13B" 'kopia minutę po podłączeniu dysku [zmiana]' && has "$RP13B" 'ZAPISZ ZMIANY (1)' \
   && ! grep -qF '6/6 kiedy' "$RP/wt.log" && ! grep -qF '4/6 rodzaj' "$RP/wt.log"; then
    ok "replica: U8/E-1 -- karta jak przy relacji (nagłówek, '*' i [zmiana], licznik przy zapisie); 'Po włożeniu' przełącza od razu, Zapisz = --on-insert=yes + reguła, bez innych kroków"
else
    bad "replica: U8 lista zmiany" "$RPOUT" "$(cat "$RP/zb.log")" "$(printf '%s' "$RP13" | cut -c1-400)" "$(printf '%s' "$RP13B" | cut -c1-400)"
fi
rm -rf "$RP"

# ============================================================================
# X12 drzewo z kratkami (tui/tree.py): okno wyboru datasetow zastapilo koszyk (lista + Dodaj
# miejsce / Wyjatki / Usun). Tu jedzie PRAWDZIWYM kodem w trybie --keys (ten sam render, co
# w curses) na pliku spec, ktory piszemy sami; sprawdzany jest wynik (--out) i ekran z liniami
# MSG. Wartosci oczekiwane zmierzone na tree.py. Kreatory (nr/rp/er) jada to samo okno wyzej
# przez $NR/bin/tree; petla curses (klawisze jako bajty terminala) -- na koncu, przez pty.
# ============================================================================
TRD="$(mktemp -d)"
mkspec() {   # <wariant> <plik>: spec okna; a (bazowy), noexc, excl, atomic, old, many
    "$PY" - "$1" "$2" <<'PYEOF'
import sys, json
v, out = sys.argv[1], sys.argv[2]
fs = [("hdd", 170000000), ("hdd/backups", 17000000), ("hdd/backups/hdd", 17000000), ("hdd/ct", 9600000),
      ("hdd/ct/subvol-301-disk-0", 5000000), ("hdd/ct/subvol-302-disk-0", 4500000), ("hdd/data", 12000000),
      ("hdd/data/docs", 5900000), ("hdd/data/mail", 3000000)]
TITLE = "Co kopiowa" + chr(263) + " z pve9b?"     # chr(), nie literal: stdin pythona na Windows nie musi byc UTF-8
spec = {"title": TITLE, "host": "pve9b", "show_mode": True, "no_exc": False, "recursion": "flat",
        "hide": ["hdd/backups"],
        "datasets": [{"name": n, "used": u, "type": "filesystem"} for n, u in fs]
                    + [{"name": "hdd/vm-101-disk-0", "used": 1500000000, "type": "volume"}],
        "roots": ["hdd/ct"], "excl": {"hdd/ct": []}}
if v == "noexc":
    spec["no_exc"] = True; spec["show_mode"] = False
elif v == "excl":
    spec["excl"] = {"hdd/ct": ["hdd/ct/subvol-301-disk-0"]}
elif v == "atomic":
    spec["recursion"] = "atomic"
elif v == "old":
    spec["datasets"].append({"name": "hdd/data/docs/old", "used": 1000000, "type": "filesystem"})
    spec["roots"] = ["hdd/data"]; spec["excl"] = {"hdd/data": ["hdd/data/docs"]}
elif v == "many":
    # 61 wierszy (tank + 60 dzieci), nic zaznaczonego, bez wiersza "Sposob" -- okno musi przewijac
    spec = {"title": TITLE,
            "datasets": [{"name": "tank", "used": 1000000, "type": "filesystem"}]
                        + [{"name": "tank/vm-%03d" % i, "used": 1000000, "type": "filesystem"} for i in range(60)],
            "roots": [], "excl": {}}
with open(out, "w", encoding="utf-8") as f:
    json.dump(spec, f, ensure_ascii=False)
PYEOF
}
trun() {   # <spec> <klawisze> -> ekran + linie MSG na stdout; wynik w $TRD/out.json; rc = rc tree.py (0 Dalej, 1 Wstecz)
    "$PY" "$REPO/tui/tree.py" --spec "$1" --out "$TRD/out.json" --keys "$2" --height 24
}
tjq() {   # <plik out> <klucz> [podklucz...] -> ta wartosc jako zwarty JSON (pusty, gdy brak pliku/klucza)
    "$PY" -c 'import sys, json
o = json.load(open(sys.argv[1], encoding="utf-8"))
for k in sys.argv[2:]:
    o = o[k]
print(json.dumps(o, separators=(",", ":")))' "$@" 2>/dev/null | tr -d '\r'
}
# U68: tryb JEDNEJ pozycji (Przeglądaj kopię i każdy wybór jednego datasetu): Enter wybiera; na
# gałęzi bez migawek ("selectable" jej nie zawiera) Enter ją rozwija i mówi o tym; kratek nie ma.
cat > "$TRD/single.json" <<'SJ'
{"title": "t", "single": true, "selectable": ["hdd/lab/vm-101", "hdd/labbrowse/v-ntfs"],
 "datasets": [{"name": "hdd", "type": "filesystem"}, {"name": "hdd/lab", "type": "filesystem"},
              {"name": "hdd/lab/vm-101", "type": "filesystem"}, {"name": "hdd/labbrowse", "type": "filesystem"},
              {"name": "hdd/labbrowse/v-ntfs", "type": "volume"}]}
SJ
TRS=$(trun "$TRD/single.json" 'enter,down,enter,down,enter'); TRSRC=$?
if [ "$TRSRC" -eq 0 ] && [ "$(tjq "$TRD/out.json" roots)" = '["hdd/lab/vm-101"]' ] \
   && printf '%s' "$TRS" | grep -q 'MSG: hdd nie można wybrać' && ! printf '%s' "$TRS" | grep -q '\[x\]\|\[ \]'; then
    ok "tree U68: tryb jednej pozycji -- Enter na gałęzi rozwija i mówi, Enter na datasecie wybiera; bez kratek"
else
    bad "tree U68: tryb jednej pozycji" "rc=$TRSRC out=$(cat "$TRD/out.json")" "$TRS"
fi
TRS=$(trun "$TRD/single.json" 'esc'); TRSRC=$?
if [ "$TRSRC" -eq 1 ] && [ "$(tjq "$TRD/out.json" action)" = '"back"' ]; then
    ok "tree U68: tryb jednej pozycji -- Esc = Wstecz, nic nie wybrane"
else
    bad "tree U68: Esc w trybie jednej pozycji" "rc=$TRSRC out=$(cat "$TRD/out.json")"
fi
mkspec a "$TRD/a.json"; mkspec noexc "$TRD/noexc.json"; mkspec excl "$TRD/excl.json"
mkspec atomic "$TRD/atomic.json"; mkspec old "$TRD/old.json"; mkspec many "$TRD/many.json"
# a) w zaznaczonym miejscu Spacja na dziecku = wyjatek, Enter = Dalej; cel kopii (hide) w ogole nie widac
TRA=$(trun "$TRD/a.json" 'right,down,space,enter'); TRARC=$?
if [ "$TRARC" -eq 0 ] && [ "$(tjq "$TRD/out.json" action)" = '"next"' ] && [ "$(tjq "$TRD/out.json" roots)" = '["hdd/ct"]' ] \
   && [ "$(tjq "$TRD/out.json" excl hdd/ct)" = '["hdd/ct/subvol-301-disk-0"]' ] && has "$TRA" 'pominięte: 1'; then
    ok "tree: Spacja na dziecku zaznaczonego miejsca = wyjatek (excl hdd/ct = [subvol-301]), Enter = next, ekran mowi 'pominięte: 1'"
else
    bad "tree: wyjatek pod miejscem" "rc=$TRARC" "$TRA" "$(cat "$TRD/out.json" 2>/dev/null)"
fi
TR0=$(trun "$TRD/a.json" '')
if ! has "$TR0" 'backups' && has "$TR0" 'zvol 1.4G'; then
    ok "tree: cel kopii (hide) niewidoczny na ekranie startowym, zvol z rozmiarem ('zvol 1.4G')"
else
    bad "tree: ekran startowy (hide, zvol)" "$TR0"
fi
# b) zaznaczenie rodzica, pod ktorym lezy cel kopii: cel pomijany sam, z komunikatem
TRB=$(trun "$TRD/a.json" 'up,space,enter'); TRBRC=$?
if [ "$TRBRC" -eq 0 ] && [ "$(tjq "$TRD/out.json" roots)" = '["hdd"]' ] && [ "$(tjq "$TRD/out.json" excl hdd)" = '["hdd/backups"]' ] \
   && has "$TRB" 'MSG: Cel kopii hdd/backups pominięty automatycznie.'; then
    ok "tree: miejsce nad celem kopii (hdd) -> cel dopisany do wyjatkow sam (excl hdd = [hdd/backups]), komunikat o tym"
else
    bad "tree: cel kopii pod nowym miejscem" "rc=$TRBRC" "$TRB" "$(cat "$TRD/out.json" 2>/dev/null)"
fi
# (2026-10-26: zaznaczony z dziecmi odznacza DRUGA Spacja -- pierwsza daje [-], obecne bez przyszlych.)
# c) Enter bez zadnego miejsca odmawia (zostaje w oknie); bez Enter/Esc koniec to Wstecz (rc 1)
TRC=$(trun "$TRD/a.json" 'space,space,enter'); TRCRC=$?
if [ "$TRCRC" -eq 1 ] && [ "$(tjq "$TRD/out.json" action)" = '"back"' ] && has "$TRC" 'MSG: Zaznacz co najmniej jedno miejsce (Spacja).'; then
    ok "tree: zdjecie jedynego miejsca i Enter = odmowa 'Zaznacz co najmniej jedno miejsce', wynik action=back, rc=1"
else
    bad "tree: Enter bez miejsca" "rc=$TRCRC" "$TRC" "$(cat "$TRD/out.json" 2>/dev/null)"
fi
# d) no_exc (Zmien relacje: add-source bierze cale miejsce): wyjatku nie ma, a miejsce nad celem kopii odmowa
TRD1=$(trun "$TRD/noexc.json" 'right,down,space')
TRD2=$(trun "$TRD/noexc.json" 'up,space')
if has "$TRD1" 'MSG: Tu nie da się pominąć samego' && has "$TRD2" 'MSG: Pod hdd leży cel kopii (hdd/backups). Zaznacz węższe miejsce.'; then
    ok "tree: no_exc -- Spacja na dziecku miejsca odmawia ('Tu nie da się pominąć samego'), miejsce nad celem kopii tez ('Zaznacz węższe miejsce')"
else
    bad "tree: no_exc" "$TRD1" "$TRD2"
fi
# e) tryb atomowy (klawisz S) nie wlacza sie przy wyjatkach; zdjecie wyjatku Spacja na odznaczonym
TRE1=$(trun "$TRD/excl.json" 's,enter'); TRE1RC=$?
TRE1R="$(tjq "$TRD/out.json" recursion)"
TRE2=$(trun "$TRD/excl.json" 'right,space,enter'); TRE2RC=$?
if [ "$TRE1RC" -eq 0 ] && [ "$TRE1R" = '"flat"' ] \
   && has "$TRE1" 'MSG: Kopiowanie atomowe (-r) nie pozwala pomijać. Zdejmij najpierw pominięte (odznaczone) datasety.' \
   && [ "$TRE2RC" -eq 0 ] && [ "$(tjq "$TRD/out.json" excl hdd/ct)" = '[]' ]; then
    ok "tree: S przy wyjatkach odmawia i zostaje -R (recursion=flat); Spacja na odznaczonym zdejmuje wyjatek (excl hdd/ct = [])"
else
    bad "tree: S przy wyjatkach / zdjecie wyjatku" "rc=$TRE1RC" "$TRE1R" "$TRE1" "rc=$TRE2RC" "$(cat "$TRD/out.json" 2>/dev/null)"
fi
# f) tryb atomowy (-r) nie pozwala pomijac czesci galezi
TRF=$(trun "$TRD/atomic.json" 'right,down,space')
if has "$TRF" 'MSG: Przy kopiowaniu atomowym (-r) nie da się pominąć części gałęzi.'; then
    ok "tree: tryb atomowy -- Spacja na dziecku miejsca odmawia ('nie da się pominąć części gałęzi')"
else
    bad "tree: wyjatek w trybie atomowym" "$TRF"
fi
# g) dataset pod pominietym: komunikat wskazuje, co zaznaczyc najpierw
TRG=$(trun "$TRD/old.json" 'goto:hdd/data/docs/old,space')
if has "$TRG" 'MSG: hdd/data/docs/old jest pomijany razem z hdd/data/docs. Zaznacz najpierw hdd/data/docs.'; then
    ok "tree: dataset pod pominietym (docs/old) nie da sie zaznaczyc osobno -- komunikat 'Zaznacz najpierw hdd/data/docs'"
else
    bad "tree: dataset pod pominietym" "$TRG"
fi
# h) 60 dzieci przy 24 wierszach: okno przewija, obie strzalki "więcej", zaznaczony wiersz widoczny
TRH=$(trun "$TRD/many.json" 'pgdn,pgdn,down,space')
if has "$TRH" '↑ więcej' && has "$TRH" '↓ więcej' && has "$TRH" '[x] vm-030'; then
    ok "tree: 60 dzieci na 24 wierszach -- PgDn przewija, '↑ więcej' i '↓ więcej', zaznaczony vm-030 widoczny"
else
    bad "tree: przewijanie dlugiej listy" "$TRH"
fi
# i) PRAWDZIWA petla curses przez pty (klawisze jako bajty terminala, jak pty-keys wyzej)
TRPO="$TRD/out-pty.json"; rm -f "$TRPO"
TRPT="$("$PY" "$REPO/test/tui/pty-keys.py" "$REPO/tui/tree.py" 'right,down,space,enter' -- --spec "$TRD/a.json" --out "$TRPO" 2>&1)"; TRPTRC=$?
if [ "$TRPTRC" -eq 2 ]; then
    echo "SKIP pty drzewo: brak modulu pty (Windows) -- klawisze przez petle curses sprawdza CI"
elif [ "$(tjq "$TRPO" excl hdd/ct)" = '["hdd/ct/subvol-301-disk-0"]' ]; then
    ok "tree: pty -- strzalki, Spacja i Enter przez prawdziwa petle curses daja ten sam wynik co --keys (excl hdd/ct = [subvol-301])"
else
    bad "tree: pty (petla curses)" "rc=$TRPTRC" "$TRPT" "$(cat "$TRPO" 2>/dev/null)"
fi
# Home/End z PuTTY (ESC [ 1 ~ / ESC [ 4 ~ przy TERM=xterm) przed tymi samymi klawiszami: wynik
# ten sam. Przed poprawką goły Esc z tego ciągu zamykał drzewo jako Wstecz (kampania 2026-10-22).
rm -f "$TRPO"
TRPT="$("$PY" "$REPO/test/tui/pty-keys.py" "$REPO/tui/tree.py" 'end-vt,home-vt,right,down,space,enter' -- --spec "$TRD/a.json" --out "$TRPO" 2>&1)"; TRPTRC=$?
if [ "$TRPTRC" -eq 2 ]; then
    echo "SKIP pty drzewo Home/End: brak modulu pty (Windows)"
elif "$PY" "$REPO/tui/tree.py" --keys 'end,home,right,down,space,enter' --spec "$TRD/a.json" --out "$TRD/out-k.json" >/dev/null 2>&1;      [ "$(tjq "$TRPO" action)" = '"next"' ] && [ "$(cat "$TRPO")" = "$(cat "$TRD/out-k.json")" ]; then
    ok "tree: pty -- Home/End jako ESC[1~/ESC[4~ (PuTTY) dzialaja jak Home/End (wynik = --keys end,home,...), nie zamykaja drzewa jak Esc"
else
    bad "tree: pty Home/End z PuTTY" "rc=$TRPTRC" "$(cat "$TRPO" 2>/dev/null)" "$(cat "$TRD/out-k.json" 2>/dev/null)"
fi
rm -rf "$TRD"

# ============================================================================
# template: OKNA SZABLONU (F5, uwaga 24, 2026-10-09). Ta sama atrapa whiptaila; zb
# odpowiada list-profiles i zapisuje save-profile/delete-profile. Sprawdzane: nowy
# szablon pyta o kazdy szczebel po kolei i podaje tylko ZMIENIONE (--tier= --keep=);
# 'e' na fabrycznym nie zapisuje nic; Del na wlasnym: plan czasownika, potem --yes.
# ============================================================================
TP="$(mktemp -d)"; mkdir -p "$TP/bin"
cp "$NR/bin/whiptail" "$TP/bin/whiptail"
cat > "$TP/bin/zb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${NR_DIR:?}/zb.log"
case "$1" in
    list-profiles) echo '{"profiles":[{"name":"d7h24","source":"package","used_by":0,"description":"7 dobowych + 24 godzinowe","tiers":[{"name":"hourly","keep":"24","retain":"","quiesce":"","send_schedule":"1 * * * *","pattern":"automated_hourly"},{"name":"daily","keep":"7","retain":"","quiesce":"auto,degrade","send_schedule":"11 1 * * *","pattern":"automated_daily"}]},{"name":"moj","source":"user","used_by":2,"description":"","tiers":[{"name":"daily","keep":"14","retain":""}]},{"name":"drab","source":"package","used_by":0,"description":"drabina","tiers":[{"name":"standard_hourly","keep":"","retain":"","quiesce":"","send_schedule":"1 * * * *","pattern":""},{"name":"keep_hourly","keep":"24","retain":"","quiesce":"","send_schedule":"","pattern":"automated_hourly"},{"name":"keep_daily","keep":"7","retain":"","quiesce":"","send_schedule":"","pattern":"automated_hourly"}]}]}' ;;
    save-profile) echo ">>> atrapa: zapisano" ;;
    delete-profile) case " $* " in *" --yes "*) echo ">>> atrapa: usunieto" ;; *) echo "PLAN (delete-profile):"; echo "  built from it: 2 relationship(s)" ;; esac ;;
    *) echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
chmod +x "$TP/bin/zb"
tp_run() {   # <akcja> <nazwa> <odpowiedzi> -> stdout okien; dzienniki w $TP
    rm -f "$TP/wt.log" "$TP/wt.n" "$TP/zb.log"
    printf '%s' "$3" > "$TP/answers"
    ( export NR_DIR="$TP" WHIPTAIL="$TP/bin/whiptail" ZFS_BACKUP="$TP/bin/zb" PYTHON="$PY"
      [ -n "${ZFS_GRID_KEYS:-}" ] && export ZFS_GRID="$PY $REPO/tui/grid.py --keys $ZFS_GRID_KEYS"
      bash "$REPO/tui/template.sh" "$1" "$2" ) 2>"$TP/err" </dev/null
}
# Okno-tabela (tui/grid.py, curses) jedzie PRAWDZIWYM kodem w trybie --keys; ZFS_GRID
# podstawia klawisze zamiast terminala. Whiptail zostaje na plan i komunikaty.
tp_grid() {   # <klawisze> <akcja> <nazwa> <odpowiedzi whiptail> -> jak tp_run
    local keys="$1"; shift
    ZFS_GRID_KEYS="$keys" tp_run "$@"
}
# 1. NOWY w jednym oknie: nazwa (pole na gorze), godzinowe 24 -> 48 w tabeli, opis z
#    wyborow (dobowe w bazowym zamraza), plan, WYKONAJ.
TPOUT=$(tp_grid "bs,bs,bs,bs,bs,bs,bs,bs,bs,m,o,j,7,down,down,right,bs,bs,4,8,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -qx 'save-profile --from=d7h24 --as=moj7 --tier=hourly --keep=48 --description=48 godzinowych + 7 dobowych; zamraża: dobowych' "$TP/zb.log" \
   && grep -qF 'godzinowe: 24 -> 48' "$TP/wt.log" && grep -qF 'dobowe: 7  (bez zmian)' "$TP/wt.log"; then
    ok "template: nowy w JEDNYM oknie-tabeli -- nazwa, liczby, opis z wyborow; plan podaje tylko zmienione"
else
    bad "template: nowy szablon (tabela)" "rc=$TPRC" "$TPOUT" "$(cat "$TP/zb.log")" "$(tail -5 "$TP/wt.log" | cut -c1-250)" "$(cat "$TP/err")"
fi
# 2. ZAMRAZANIE TO KRATKA w tabeli (wlasciciel 2026-10-09): odznaczenie dobowego daje
#    --tier=daily --quiesce= (pole zdjete), opis "bez zamrazania".
TPOUT=$(tp_grid "down,down,down,right,right,space,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -qx 'save-profile --from=d7h24 --as=d7h24-moj --tier=daily --quiesce= --description=24 godzinowych + 7 dobowych; bez zamrażania' "$TP/zb.log" \
   && grep -qF 'zamrażanie dobowe: tak -> nie' "$TP/wt.log"; then
    ok "template: kratka zamrazania w tabeli -- odznaczenie = --quiesce=, opis z wyborow"
else
    bad "template: zamrazanie (tabela)" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(tail -5 "$TP/wt.log" | cut -c1-300)" "$(cat "$TP/err")"
fi
# 3. Wlasciciel 2026-10-09 (uwaga 3): szczebel, ktory SAM robi i sprzata swoje migawki,
#    wylacza sie bez przeszkod (--drop-tier). Pilnowana jest tylko drabina: ostatniego
#    szczebla sprzatajacego cudza rodzine nie da sie wylaczyc (okno mowi, w ramce).
#    Wszystkich szczebli tez nie: "Zostaw wlaczony choc jeden szczebel."
TPOUT=$(tp_grid "down,down,space,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -q '^save-profile --from=d7h24 --as=d7h24-moj --drop-tier=hourly ' "$TP/zb.log"; then
    ok "template: szczebel z wlasna rodzina wylacza sie (--drop-tier), bez straznika"
else
    bad "template: wylaczenie szczebla z wlasna rodzina" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | tail -8)"
fi
TPOUT=$(tp_grid "down,down,space,down,space,enter" new d7h24 ""); TPRC=$?
if [ "$TPRC" -ne 0 ] && ! grep -q '^save-profile' "$TP/zb.log" && printf '%s' "$TPOUT" | grep -qF 'Zostaw włączony choć jeden szczebel.'; then
    ok "template: wszystkich szczebli wylaczyc sie nie da -- okno mowi, nic nie zapisuje"
else
    bad "template: wylaczenie wszystkich" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | tail -8)"
fi
TPOUT=$(tp_grid "down,down,down,space,down,space" new drab ""); TPRC=$?
GRIDSCR=$(printf '%s' "$TPOUT")
if [ "$TPRC" -ne 0 ] && ! grep -q '^save-profile' "$TP/zb.log" && printf '%s' "$GRIDSCR" | grep -qF 'Nie można wyłączyć' \
   && printf '%s' "$GRIDSCR" | grep -E '^│ +Nie można wyłączyć' | grep -q '│$' && ! printf '%s' "$GRIDSCR" | grep -qE '^Nie można wyłączyć'; then
    ok "template: drabina -- ostatniego szczebla sprzatajacego rodzine nie da sie wylaczyc; komunikat w ramce, bez kopii pod nia"
else
    bad "template: drabina, ostatni szczebel" "rc=$TPRC" "$GRIDSCR" "$(cat "$TP/zb.log")"
fi
# 3b. Uwaga 2: kursor w polu nazwy chodzi po tekscie -- Home, wpis na poczatku, End,
#     cztery w lewo, Del w srodku.
TPOUT=$(tp_grid "home,x,end,left,left,left,left,del,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -q '^save-profile --from=d7h24 --as=xd7h24moj ' "$TP/zb.log"; then
    ok "template: pole nazwy -- kursor chodzi po tekscie (Home/End/strzalki), Del kasuje w srodku"
else
    bad "template: edycja nazwy w miejscu" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | head -5)"
fi
TPOUT=$(tp_run edit d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && ! grep -q '^save-profile' "$TP/zb.log" && grep -qF 'nie zmienisz' "$TP/wt.log"; then
    ok "template: 'e' na fabrycznym -- okno mowi, ze Ins robi kopie; nic nie zapisuje"
else
    bad "template: zmiana fabrycznego" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(cat "$TP/wt.log" | cut -c1-200)"
fi
TPOUT=$(tp_run delete moj "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -qx 'delete-profile moj' "$TP/zb.log" && grep -qx 'delete-profile moj --yes' "$TP/zb.log" \
   && grep -F 'Usunięcie szablonu moj' "$TP/wt.log" | grep -qF -- '--defaultno' && grep -qF 'bo tego szablonu już nie będzie' "$TP/wt.log"; then
    ok "template: Del na wlasnym -- plan czasownika (2 relacje: zostaja, ale bez szablonu do odswiezenia), domyslnie Wstecz, potem --yes"
else
    bad "template: usuwanie" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(tail -3 "$TP/wt.log" | cut -c1-250)"
fi
# 4. OKNO KOMPLETNE (wlasciciel 2026-10-09: "pokazywac rowniez miesieczne, roczne,
#    tygodniowe po prostu nie pozaznaczane"): d7h24 ma dwa szczeble, tabela ma piec;
#    zaznaczenie tygodniowego = --add-tier=weekly (domyslnie 4, zamrazany jak dobowy).
TPOUT=$(tp_grid "down,down,down,down,space,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -qx 'save-profile --from=d7h24 --as=d7h24-moj --add-tier=weekly --description=24 godzinowych + 7 dobowych + 4 tygodniowych; zamraża: dobowych, tygodniowych' "$TP/zb.log" \
   && printf '%s' "$TPOUT" | grep -qE '\[ \] miesięczne' && printf '%s' "$TPOUT" | grep -qE '\[ \] roczne' \
   && grep -qF 'tygodniowe: dodany, 4, zamrażany' "$TP/wt.log"; then
    ok "template: tabela pokazuje wszystkie piec szczebli; brakujace odznaczone, kratka = --add-tier"
else
    bad "template: dodanie szczebla" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | tail -20)" "$(tail -3 "$TP/wt.log" | cut -c1-300)" "$(cat "$TP/err")"
fi
# 5. Drabina (jedna rodzina): dodany szczebel to nowy szczebel drabiny -- bez kratki
#    zamrazania (zamraza sie szczebel, ktory robi migawki); liczba zmieniona = --keep po --add-tier.
TPOUT=$(tp_grid "down,down,down,down,down,down,down,space,right,bs,3,enter" new drab "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -q '^save-profile --from=drab --as=drab-moj --add-tier=yearly --keep=3 --description=' "$TP/zb.log" \
   && ! grep -q -- '--quiesce' "$TP/zb.log" && grep -qF 'roczne: dodany, 3' "$TP/wt.log"; then
    ok "template: drabina -- dodany szczebel roczny z liczba, bez zamrazania"
else
    bad "template: dodanie szczebla drabiny" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | tail -20)" "$(cat "$TP/err")"
fi
# 6. SPOSOB LICZENIA (wlasciciel 2026-10-09: "brakuje w oknie wyboru (*) GFS () AGE () FLAT
#    -- z wyjasnieniem roznicy"): wybor nad tabela, objasnienie wybranego; WIEK = --method=age,
#    liczby zostaja, jednostka przy liczbie (dni / godz.) i zmieniona liczba jako --retain.
TPOUT=$(tp_grid "down,right,space,down,down,bs,1,4,enter" new d7h24 "0${T}
"); TPRC=$?
if [ "$TPRC" -eq 0 ] && grep -qx 'save-profile --from=d7h24 --as=d7h24-moj --method=age --tier=daily --retain=-d14 --description=24 godzinowych + 14 dobowych; zamraża: dobowych' "$TP/zb.log"    && printf '%s' "$TPOUT" | grep -qF '( ) GFS   (*) WIEK (age)   ( ) PŁASKI (flat)' && printf '%s' "$TPOUT" | grep -qF 'Kasuje migawki starsze niż N okresów'    && grep -qF 'sposób: PŁASKI (flat) -> WIEK (age) (liczby zostają)' "$TP/wt.log" && grep -qF 'dobowe: 7 -> 14 dni' "$TP/wt.log"; then
    ok "template: wybor sposobu (GFS / WIEK / PLASKI) z objasnieniem; WIEK = --method=age, liczba jako --retain"
else
    bad "template: wybor sposobu" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | head -14)" "$(tail -3 "$TP/wt.log" | cut -c1-300)" "$(cat "$TP/err")"
fi
# 7. Drabina liczy tylko GFS: wybor zablokowany, okno mowi dlaczego, nic sie nie zmienia.
TPOUT=$(tp_grid "down,right,space" new drab ""); TPRC=$?
if [ "$TPRC" -ne 0 ] && ! grep -q '^save-profile' "$TP/zb.log" && printf '%s' "$TPOUT" | grep -qF '(*) GFS'    && printf '%s' "$TPOUT" | grep -qF 'MSG: Drabina na jednej rodzinie migawek liczy tylko GFS.'; then
    ok "template: drabina -- wybor sposobu zablokowany na GFS, okno mowi dlaczego"
else
    bad "template: drabina, sposob" "rc=$TPRC" "$(cat "$TP/zb.log")" "$(printf '%s' "$TPOUT" | head -14)"
fi
# X1 (wlasciciel 2026-10-12): szczebel WYLACZONY ma "koherentne" odznaczone -- takze ten,
# ktorego szablon nie ma (tygodniowe, roczne); wlaczony dostaje zamrazanie z szablonu.
TPOUT=$(tp_grid "none" new d7h24 ""); TPRC=$?
TPON=$(tp_grid "down,down,down,down,space" new d7h24 "")
if printf '%s' "$TPOUT" | grep -qE '\[ \] tygodniowe +— +\[ \]' && printf '%s' "$TPOUT" | grep -qE '\[ \] roczne +— +\[ \]'    && printf '%s' "$TPOUT" | grep -qE '\[X\] dobowe +7 +\[X\]' && printf '%s' "$TPON" | grep -qE '\[X\] tygodniowe +[0-9]+ +\[X\]'; then
    ok "template: X1 -- wylaczony szczebel ma koherentne odznaczone; wlaczony dostaje zamrazanie z szablonu"
else
    bad "template: X1 koherentne przy wylaczonym szczeblu" "$(printf '%s' "$TPOUT" | grep -E 'SZCZEBEL|\] ')" "$(printf '%s' "$TPON" | grep -E '\] ')"
fi
rm -rf "$TP"

# ============================================================================
# P4 (wlasciciel 2026-10-09): relacja "z szablonu i recznie" -- ukryty szablon relacji.
# Kreator: krok 6 "Recznie..." = tabela szczebli (tui/template.sh relation), wynik
# save-profile --hidden jako relacja-<NAZWA>; zmiana nazwy w kroku 7 przenosi szkic.
# ============================================================================
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}__manual__
0${T}pve9b
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE='goto:hdd/data,space,enter'); NRRC=$?
if [ "$NRRC" -eq 0 ] && grep -q '^save-profile --from=d7h24 --as=relacja-pve9b --hidden --force --description=' "$NR/zb.log" \
   && has "$NROUT" "--profile=relacja-pve9b " && ! grep -q '^delete-profile' "$NR/zb.log"; then
    ok "new-relation: Recznie -- tabela szczebli, ukryty szablon relacja-<nazwa> (--hidden), relacja z --profile=relacja-<nazwa>"
else
    bad "new-relation: Recznie" "rc=$NRRC" "$(cat "$NR/zb.log")" "$(tail -3 "$NR/err")"
fi
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/backups
0${T}__manual__
0${T}
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
" NR_TREE='goto:hdd/data,space,enter'); NRRC=$?
# Wlasciciel 2026-10-29: relacja z drugim hostem nazywa sie jak ten host -- zmiany nazwy w
# kroku 7 juz nie ma, wiec szkic "Recznie" zostaje relacja-<host>, nic sie nie przenosi.
if [ "$NRRC" -eq 0 ] && has "$NROUT" "--name=pve9b " && has "$NROUT" "--profile=relacja-pve9b " \
   && ! grep -q '^delete-profile' "$NR/zb.log" && ! grep -qF 'Pod tą nazwą relacja będzie widoczna' "$NR/wt.log"; then
    ok "new-relation: Recznie -- bez okna nazwy (nazwa = host), szkic relacja-<host> bez przenoszenia"
else
    bad "new-relation: Recznie + zmiana nazwy" "rc=$NRRC" "$(cat "$NR/zb.log")"
fi

# Zmien relacje (tui/edit-relation.sh): od U25 pierwsze okno to KARTA "Relacja r1" (ta sama co w
# kreatorze); "Harmonogram" (tag harmon) = lista szablonow z "Ręcznie…" (__manual__) na gorze ->
# tabela celu (template.sh relation); "Retencja źródła" (tag srcret) = samo okno zrodla -> plan.
ER="$(mktemp -d)"; mkdir -p "$ER/bin"
cp "$NR/bin/whiptail" "$ER/bin/whiptail"
cp "$NR/bin/tree" "$ER/bin/tree"    # okno-drzewo (patrz $NR/bin/tree): stan w $NR_DIR = $ER
cat > "$ER/bin/zb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${NR_DIR:?}/zb.log"
case "$1" in
    status)         echo '{"relations":[{"name":"r1","state":"'"${ER_STATE:-active}"'","profile":"d7h24","source_profile":"","peer_host":"'"${ER_PEER-192.168.28.99}"'","active_endpoint":"'"${ER_EP:-192.168.28.99:22}"'","installed_endpoint":"192.168.28.99:22","passive":"'"${ER_MIRROR:-0}"'","sources":["root@192.168.28.99:hdd/data"]}]}' ;;
    activate)       echo ">>> atrapa: activate" ;;
    list-profiles)  cat "${NR_FIX:?}/list-profiles.json" ;;
    save-profile)   echo "save-profile: ok (atrapa)" ;;
    delete-profile) echo "delete-profile: ok (atrapa)" ;;
    edit-relation)  if [ -n "${ER_NEWREL:-}" ]; then echo "FATAL: edit-relation: profile 'd30h24' stamps [x] on hdd/ct, the installed relationship stamps [] -- no family in common. That is a NEW relationship (delete-relation, then create it again), not an edit. Nothing was changed."; exit 1; fi
                    case " $* " in *" --yes "*) echo ">>> atrapa: zmieniono" ;; *) echo "Relation edit: r1 (atrapa)"; echo
                        # X6: ER_HAND = config zmieniony recznie (minuta 29), plan wpisze 31.
                        [ -n "${ER_HAND:-}" ] && printf -- '--- proposed config: /etc/x.conf ---\n  [template:profile__relacja-r1__daily]\n  -\tprune_schedule = 29 1 * * *\n  +\tprune_schedule = 31 1 * * *\n\n' || : ;;
                    esac ;;
    list-datasets)  echo '{"datasets":[{"name":"hdd"},{"name":"hdd/data"},{"name":"hdd/data/mail"},{"name":"hdd/iso"},{"name":"hdd/vm"}]}' ;;
    relation-sources) printf 'hdd/data\tflat\n' ;;
    set-datasets)   # X21: hdd/vm "lezy w celu" -- plan (bez --yes) odmawia, jak prawdziwy czasownik.
                    case " $* " in *" --dataset=hdd/vm:"*) echo "FATAL: set-datasets: target 'hdd/backups' overlaps 'hdd/vm' (atrapa)"; exit 1 ;; esac
                    echo ">>> atrapa: set-datasets" ;;
    add-source|remove-source)
                    # X21: hdd/vm "lezy w celu" -- plan (bez --yes) odmawia, jak prawdziwy czasownik.
                    if [ "$3" = hdd/vm ]; then echo "FATAL: add-source: target 'hdd/backups' overlaps 'hdd/vm' (atrapa)"; exit 1; fi
                    echo ">>> atrapa: $1 $2 $3" ;;
    show-config)    echo '{"sections":[{"kind":"dataset","name":"hdd/backups/192.168.28.99/hdd/data","fields":{"pair_label":"r1","compression":"none"'"${ER_RAW:+,\"raw\":\"yes\"}"'}}]}' ;;
    set-transfer)   case " $* " in *" --yes "*) echo ">>> atrapa: set-transfer" ;; *) echo "Relation 'r1': history=newest (sections: 1)"; echo "plan only -- nothing installed (add --yes to install)" ;; esac ;;
    show-tiers)     echo '{"name":"r1","mode":"remote","config":"/x.conf","target":[{"name":"hourly","mechanism":"flat","pattern":"automated_hourly","prefix":"automated_hourly_","keep":"24","retain":"","gfs":"","quiesce":"","send_schedule":"1 * * * *","prune_schedule":"21 * * * *","monitor_warn":"","monitor_crit":""},{"name":"daily","mechanism":"flat","pattern":"automated_daily","prefix":"automated_daily_","keep":"7","retain":"","gfs":"","quiesce":"auto,degrade","send_schedule":"11 1 * * *","prune_schedule":"31 1 * * *","monitor_warn":"","monitor_crit":""}],"source":[{"name":"hourly","mechanism":"flat","pattern":"automated_hourly","keep":"'"${ER_SRC_KEEP:-24}"'","retain":""},{"name":"daily","mechanism":"flat","pattern":"automated_daily","keep":"7","retain":""}]}' ;;
    set-tiers)      case " $* " in *" --yes "*) echo ">>> atrapa: set-tiers" ;; *) echo "Relation 'r1' -- tiers:"; echo "  hourly: keep=12 (source)"; echo "plan only -- nothing installed (add --yes to install)" ;; esac ;;
    *)            echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
# Kazde okno-tabela bierze KOLEJNA linie klawiszy z $ER/gridkeys (brak linii = Esc):
# tabela szczebli i okno retencji zrodla dostaja rozne klawisze, a powrot do tabeli
# po Wstecz z planu nie kreci sie w kolko.
cat > "$ER/bin/grid" <<'EOF'
#!/bin/bash
n=$(cat "$NR_DIR/grid.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$NR_DIR/grid.n"
k=$(sed -n "${n}p" "$NR_DIR/gridkeys"); [ -n "$k" ] || k=esc
exec $GRID_PY "$GRID_REPO/tui/grid.py" --keys "$k" "$@"
EOF
chmod +x "$ER/bin/zb" "$ER/bin/grid" "$ER/bin/tree"
er_run() {   # <odpowiedzi> [klawisze tabel, linia na okno] -> stdout; dzienniki w $ER
    # Drzewo wyboru datasetow (Datasety): klawisze z ER_TREE (env przed wywolaniem), jedna linia
    # na wywolanie okna, linie rozdzielone '|'; brak linii = Esc.
    rm -f "$ER/wt.log" "$ER/wt.n" "$ER/zb.log" "$ER/grid.n" "$ER/tree.n" "$ER/tree.log" "$ER/treekeys"
    printf '%s' "$1" > "$ER/answers"
    printf '%b\n' "${2:-enter\nenter}" > "$ER/gridkeys"
    printf '%s\n' "${ER_TREE:-}" | tr '|' '\n' > "$ER/treekeys"
    ( export NR_DIR="$ER" NR_FIX="$P10" WHIPTAIL="$ER/bin/whiptail" ZFS_BACKUP="$ER/bin/zb" PYTHON="$PY"
      export ADDR_PROBE="${ER_PROBE:-true}"   # E-2: atrapa sprawdzenia, czy pod adresem ktoś odpowiada
      export GRID_PY="$PY" GRID_REPO="$REPO" ZFS_GRID="$ER/bin/grid"
      export TREE_PY="$PY" TREE_REPO="$REPO" ZFS_TREE="$ER/bin/tree"
      bash "$REPO/tui/edit-relation.sh" r1 ) 2>"$ER/err" </dev/null
}
# W4 (wlasciciel 2026-10-11): "Datasety" = okno koszyka z kreatora, z obecnymi datasetami
# relacji; dwie zmiany (dodaj hdd/iso, usun hdd/data), JEDEN plan roznic (DOJDA / ODPADNA),
# po WYKONAJ add-source i remove-source z --yes. Bez "Sposob" i bez "Wyjatki".
# X12: okno koszyka to drzewo (tui/tree.py); dawne "add hdd/iso, del 0, next" to Spacja na hdd/iso
# (nowe miejsce), Spacja na hdd/data (obecne miejsce znika), Enter. Wstepne zaznaczenie hdd/data
# dowodzi remove-source: Spacja na NIE zaznaczonym hdd/data zrobilaby z niego miejsce, nie usuniecie.
EROUT=$(ER_TREE='goto:hdd/iso,space,goto:hdd/data,space,space,enter' er_run "0${T}dane
0${T}wykonaj
0${T}
"); ERRC=$?
ERB="$(cat "$ER/tree.log" 2>/dev/null)"
if [ "$ERRC" -eq 0 ] && grep -qx 'set-datasets r1 --dataset=hdd/iso:flat --yes' "$ER/zb.log" && ! grep -qE '^(add|remove)-source' "$ER/zb.log" \
   && grep -qF 'DOJDĄ' "$ER/wt.log" && grep -qF 'ODPADNĄ' "$ER/wt.log" && has "$ERB" 'Co kopiować z' && has "$ERB" '[ ] data' && has "$ERB" '[x] iso' \
   && ! has "$ERB" 'Wyjątki' && ! has "$ERB" 'Sposób'; then
    ok "edit-relation: Datasety -- koszyk z configu (relation-sources), kilka zmian, jeden plan DOJDA/ODPADNA, JEDNO set-datasets --yes ze stanem docelowym; bez Sposob"
else
    bad "edit-relation: Datasety (W4)" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(grep -E 'Co kopiować|DOJD|ODPAD' "$ER/wt.log" | cut -c1-250)" "$(tail -3 "$ER/err")"
fi
# RELACJA = CONFIG (właściciel 2026-10-25): jedna reguła drzewa dla każdego rodzaju relacji --
# [x] = DS:flat, [-] = DS:no + zaznaczone dzieci osobno, [ ] = nic. Pozycje z configu
# (relation-sources) -> drzewo -> pozycje: dokładnie to samo; wyjątek pod [-] znika z pozycji.
TE="$(mktemp -d)"
cat > "$TE/ds.json" <<'JSON'
{"datasets":[{"name":"hdd"},{"name":"hdd/vm-disks"},{"name":"hdd/vm-disks/a"},{"name":"hdd/vm-disks/b"},{"name":"hdd/vm-disks/b/c"},{"name":"hdd/vm-disks/vm-102"},{"name":"rpool/data"},{"name":"rpool/data/x"}]}
JSON
printf 'hdd/vm-disks\tno\nhdd/vm-disks/a\tflat\nhdd/vm-disks/b\tflat\nrpool/data\tflat\n' > "$TE/ents.tsv"
te_fn=$(sed -n '/^basket_entries() {/,/^}/p; /^basket_from_entries() {/,/^}/p' "$REPO/tui/basket-lib.sh")
got=$(PY="$PY" bash -c "$te_fn
B_ROOT=(); B_EXCL=(); B_CLOSED=''
while IFS=\$'\t' read -r k r e; do [ \"\$k\" = C ] && { B_CLOSED=\"\$r\"; continue; }; B_ROOT+=(\"\$r\"); B_EXCL+=(\"\$(printf '%s' \"\$e\" | tr '\037' '\n')\"); done < <(basket_from_entries '$TE/ds.json' '$TE/ents.tsv')
printf 'TREE:'; for i in \"\${!B_ROOT[@]}\"; do printf ' %s[%s]' \"\${B_ROOT[\$i]}\" \"\$(printf '%s' \"\${B_EXCL[\$i]}\" | tr '\n' ',')\"; done; printf ' closed=%s' \"\$B_CLOSED\"; echo
printf 'BACK:'; basket_entries '$TE/ds.json' | tr '\t\n' ': '; echo
B_EXCL[0]=\$'hdd/vm-disks/vm-102\nhdd/vm-disks/b'
printf 'EXCL-B:'; basket_entries '$TE/ds.json' | tr '\t\n' ': '; echo" 2>&1 | tr '\n' '|')
want="TREE: hdd/vm-disks[hdd/vm-disks/vm-102] rpool/data[] closed=hdd/vm-disks|BACK:hdd/vm-disks:no hdd/vm-disks/a:flat hdd/vm-disks/b:flat rpool/data:flat |EXCL-B:hdd/vm-disks:no hdd/vm-disks/a:flat rpool/data:flat |"
if [ "$got" = "$want" ]; then
    ok "drzewo <-> pozycje relacji: z configu do drzewa i z powrotem bez zmian; odznaczone dziecko pod [-] znika z pozycji"
else
    bad "drzewo <-> pozycje relacji" "got:  $got" "want: $want"
fi
# Liść (dataset bez dzieci) zachowuje rekurencję z configu: okno otwarte i zamknięte bez zmian
# nie robi z pozycji "no" pozycji "flat" (live pve11, migawki-a: "Save changes (1)" bez zmiany).
printf 'hdd/vm-disks/a\tno\n' > "$TE/cur.tsv"
got=$(PY="$PY" bash -c "$te_fn
B_ROOT=(hdd/vm-disks/a); B_EXCL=('')
basket_entries '$TE/ds.json' '$TE/cur.tsv' | tr '\t\n' ': '; echo; basket_entries '$TE/ds.json' | tr '\t\n' ': '" 2>&1 | tr '\n' '|')
if [ "$got" = "hdd/vm-disks/a:no |hdd/vm-disks/a:flat " ]; then
    ok "drzewo -> pozycje: liść zachowuje rekurencję z configu (bez fałszywej zmiany), bez configu [x] = flat"
else
    bad "drzewo -> pozycje: liść" "$got"
fi
# [-] = TYLKO OBECNE DZIECI (właściciel 2026-10-26): DS:no ze WSZYSTKIMI obecnymi dziećmi wraca do
# drzewa jako zamknięty (closed), nie jako [x] -- inaczej zapis bez zmian robił z niego DS:flat.
printf 'hdd/vm-disks\tno\nhdd/vm-disks/a\tflat\nhdd/vm-disks/b\tflat\nhdd/vm-disks/vm-102\tflat\n' > "$TE/all.tsv"
got=$(PY="$PY" bash -c "$te_fn
B_ROOT=(); B_EXCL=(); B_CLOSED=''
while IFS=\$'\t' read -r k r e; do [ \"\$k\" = C ] && { B_CLOSED=\"\$r\"; continue; }; B_ROOT+=(\"\$r\"); B_EXCL+=(\"\$e\"); done < <(basket_from_entries '$TE/ds.json' '$TE/all.tsv')
basket_entries '$TE/ds.json' | tr '\t\n' ': '" 2>&1)
if [ "$got" = "hdd/vm-disks:no hdd/vm-disks/a:flat hdd/vm-disks/b:flat hdd/vm-disks/vm-102:flat " ]; then
    ok "drzewo <-> pozycje: [-] ze wszystkimi obecnymi dziećmi wraca jako zamknięty i zapisuje się bez zmian (nie DS:flat)"
else
    bad "drzewo <-> pozycje: zamknięty [-]" "$got"
fi
# Spacja na zaznaczonym datasecie z dziećmi: [x] -> [-] (closed) -> [ ]; na liściu dalej wyjątek.
TD='{"name":"hdd"},{"name":"hdd/vm"},{"name":"hdd/vm/a"},{"name":"hdd/vm/b"}'
printf '{"datasets":[%s],"roots":["hdd/vm"],"excl":{}}' "$TD" > "$TE/spec.json"
printf '{"datasets":[%s],"roots":["hdd/vm"],"excl":{},"closed":["hdd/vm"]}' "$TD" > "$TE/spec2.json"
"$PY" "$REPO/tui/tree.py" --spec "$TE/spec.json" --out "$TE/o1.json" --keys 'goto:hdd/vm,space,enter' >/dev/null 2>&1
TS2="$("$PY" "$REPO/tui/tree.py" --spec "$TE/spec2.json" --out "$TE/o2.json" --keys 'goto:hdd/vm,space' 2>&1)"
"$PY" "$REPO/tui/tree.py" --spec "$TE/spec.json" --out "$TE/o3.json" --keys 'goto:hdd/vm/a,space,enter' >/dev/null 2>&1
if grep -qF '"closed": ["hdd/vm"]' "$TE/o1.json" && grep -qF '"roots": ["hdd/vm"]' "$TE/o1.json" \
   && has "$TS2" '[ ] vm' && grep -qF '"excl": {"hdd/vm": ["hdd/vm/a"]}' "$TE/o3.json" && grep -qF '"closed": []' "$TE/o3.json"; then
    ok "drzewo: Spacja na [x] z dziećmi -> [-] (obecne, bez przyszłych) -> [ ]; na liściu wyjątek jak dotąd"
else
    bad "drzewo: trzeci stan Spacji" "$(cat "$TE/o1.json")" "$TS2" "$(cat "$TE/o3.json")"
fi
rm -rf "$TE"
if ! grep -qE 'add-source|remove-source|needs_rerender|dataset_steps' "$REPO/tui/edit-relation.sh" \
   && grep -q '^RECURSION=flat; BASKET_NO_MODE=1; BASKET_NO_EXC=0$' "$REPO/tui/edit-relation.sh"; then
    ok "okno zmiany: bez wariantów -- wyjątki dla każdej relacji, zmiana datasetów to jedno set-datasets"
else
    bad "okno zmiany: zostały warianty" "$(grep -nE 'add-source|remove-source|needs_rerender|dataset_steps|BASKET_NO_EXC' "$REPO/tui/edit-relation.sh")"
fi
# X21 (wlasciciel 2026-10-14): zmiana datasetow sprawdzona PRZED WYKONAJ -- odmowa czasownika
# (plan bez --yes) pokazana od razu, zadnego --yes, powrot do listy.
# X12: drzewo woli sie dwa razy (po odmowie wraca lista); druga linia ER_TREE brak = Esc.
EROUT=$(ER_TREE='goto:hdd/vm,space,enter' er_run "0${T}dane
0${T}
"); ERRC=$?
if grep -q '^set-datasets r1 .*--dataset=hdd/vm:flat' "$ER/zb.log" && ! grep -q -- '--yes' <(grep -E '^set-datasets' "$ER/zb.log")    && grep -qF 'Tej zmiany nie da się zrobić' "$ER/wt.log" && grep -qF "overlaps 'hdd/vm'" "$ER/wt.log" && ! grep -qF 'DOJDĄ' "$ER/wt.log"; then
    ok "edit-relation: X21 -- Datasety: odmowa czasownika pokazana PRZED WYKONAJ, nic nie wykonane"
else
    bad "edit-relation: X21 Datasety sprawdzane przed WYKONAJ" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(grep -E 'Tej zmiany|DOJD' "$ER/wt.log" | cut -c1-200)"
fi
# W16: "Ustawienia silnika" -- obecne wartosci z show-config (kompresja none = "nie", bez
# "(fabryczne)"), zmiana historii -> set-transfer --plan, po WYKONAJ ten sam z --yes.
EROUT=$(er_run "0${T}silnik
0${T}hist
0${T}newest
0${T}__done__
0${T}wykonaj
0${T}
"); ERRC=$?
ERS="$(grep -F 'Ustawienia silnika: r1' "$ER/wt.log" | grep -F -e '--menu' | head -1)"
if [ "$ERRC" -eq 0 ] && grep -qx 'set-transfer r1 --history=newest --plan' "$ER/zb.log" && grep -qx 'set-transfer r1 --history=newest --yes' "$ER/zb.log" \
   && has "$ERS" 'Kompresja        nie ~ ' && ! has "$ERS" 'Kompresja        nie (fabryczne)' \
   && has "$ERS" 'Szyfr SSH'; then
    ok "edit-relation: Ustawienia silnika (W16) -- obecne wartosci z show-config, zmiana historii -> set-transfer --plan, po WYKONAJ --yes"
else
    bad "edit-relation: Ustawienia silnika (W16)" "rc=$ERRC" "$(cat "$ER/zb.log")" "$ERS" "$(tail -3 "$ER/err")"
fi
# LISTA ZMIAN (wlasciciel 2026-10-19: "nie mozna zmienic wiele ustawien i na koncu
# zaimplementowac, tylko po jednym kroku"): adres + silnik w jednym oknie, JEDEN plan z oboma,
# jedno WYKONAJ; czasowniki po kolei (adres pierwszy), nic przed WYKONAJ.
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9
0${T}silnik
0${T}hist
0${T}newest
0${T}__done__
0${T}wykonaj
0${T}
"); ERRC=$?
ERP=$(sed -n '/plan wszystkich zmian/,$p' "$ER/wt.log")
ERM=$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | sed -n 3p)
if [ "$ERRC" -eq 0 ] && [ "$(grep -E -e '--yes$' "$ER/zb.log" | tr '\n' '|')" = 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes|set-transfer r1 --history=newest --yes|' ] \
   && has "$ERP" 'Adres źródła: 10.99.0.9' && has "$ERP" 'Ustawienia silnika:' && has "$ERM" 'ZAPISZ ZMIANY (2)' \
   && hasE "$ERM" 'Źródło +pve9 \(192\.168\.28\.99\) -> 10\.99\.0\.9 \[zmiana\]' && hasE "$ERM" 'Silnik +historia: tylko różnica do najnowszej \[zmiana\]'; then
    ok "edit-relation: lista zmian -- adres i silnik czekaja ([zmiana] w wierszach Źródło i Silnik karty), jeden plan obu, jedno WYKONAJ, activate potem set-transfer"
else
    bad "edit-relation: lista zmian (adres + silnik)" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(printf '%s' "$ERM" | cut -c1-400)" "$(tail -3 "$ER/err")"
fi
# X10 (wlasciciel 2026-10-14): sprzecznych ustawien nie da sie wybrac -- wysylka zaszyfrowana
# (raw) bez wiersza Kompresja, lustro (passive) bez wiersza Historia; kontrola: zwykla relacja ma oba.
EROUT=$(ER_RAW=1 er_run "0${T}silnik
1${T}
"); ERW=$(grep -F 'Ustawienia silnika: r1' "$ER/wt.log" | grep -F -e '--menu' | head -1)
EROUT=$(ER_MIRROR=1 er_run "0${T}silnik
1${T}
"); ERM=$(grep -F 'Ustawienia silnika: r1' "$ER/wt.log" | grep -F -e '--menu' | head -1)
EROUT=$(er_run "0${T}silnik
1${T}
"); ERN=$(grep -F 'Ustawienia silnika: r1' "$ER/wt.log" | grep -F -e '--menu' | head -1)
if has "$ERW" 'Szyfrowane' && ! has "$ERW" 'Kompresja' && ! has "$ERM" 'Historia ' && has "$ERM" 'Kompresja'    && has "$ERN" 'Historia ' && has "$ERN" 'Kompresja'; then
    ok "edit-relation: X10 -- raw bez Kompresji, lustro bez Historii; zwykla relacja ma oba"
else
    bad "edit-relation: X10 okno silnika" "raw: $(printf '%s' "$ERW" | cut -c1-250)" "lustro: $(printf '%s' "$ERM" | cut -c1-250)" "zwykla: $(printf '%s' "$ERN" | cut -c1-250)"
fi
# W1: okno "Zmien relacje" czyta szablony BEZ renderowania (16,6 s -> 1,8 s na pve9b).
if grep -qx 'list-profiles --json --no-render' "$ER/zb.log" && ! grep -qx 'list-profiles --json' "$ER/zb.log"; then
    ok "edit-relation: list-profiles --no-render (W1: 16,6 s z renderowaniem na pve9b)"
else
    bad "edit-relation: list-profiles bez --no-render" "$(grep list-profiles "$ER/zb.log")"
fi
# ADRES HOSTA (wlasciciel 2026-10-17): kolektor wyniesiony za VPN -- na karcie wiersz "Źródło"
# (tag adres, U25), jedno pole (wypelnione zapisanym adresem), jedno WYKONAJ, potem JEDNO
# `activate r1 --host=NOWY --skip-final-catchup --yes`. Bez domkniecia kopii starym adresem.
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9
0${T}wykonaj
0${T}
"); ERRC=$?
ERA="$(grep -F 'Adres hosta: r1' "$ER/wt.log" | grep -F -e '--inputbox' | head -1)"
ERC1="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | head -1)"
if [ "$ERRC" -eq 0 ] && grep -qx 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes' "$ER/zb.log" \
   && [ "$(grep -c '^activate' "$ER/zb.log")" -eq 1 ] && ! grep -qE '^(final-catchup|set-endpoint|verify-endpoint|activate-client)' "$ER/zb.log" \
   && has "$ERA" 'Zapisany: 192.168.28.99:22' && has "$ERA" '~ 192.168.28.99:22 ~' && has "$ERA" 'po przeniesieniu kolektora' \
   && hasE "$ERC1" 'Źródło +pve9 \(192\.168\.28\.99\) ~'; then
    ok "edit-relation: Adres hosta -- pole z zapisanym adresem, WYKONAJ = jedno activate --host= --skip-final-catchup --yes"
else
    bad "edit-relation: Adres hosta" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(printf '%s' "$ERA" | cut -c1-300)" "$(printf '%s' "$ERC1" | cut -c1-300)" "$(tail -3 "$ER/err")"
fi
# LISTA ZMIAN (wlasciciel 2026-10-19): adres czeka na liscie; Wstecz z karty pyta o porzucenie
# ("Wroc" = karta, pole adresu otwarte drugi raz ma czekajacy adres), "Porzuc" = nic nie uruchomione.
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9
1${T}
1${T}
0${T}adres
1${T}
1${T}
0${T}
"); ERRC=$?
if [ "$ERRC" -eq 1 ] && ! grep -q '^activate' "$ER/zb.log" && [ "$(grep -cF 'Porzucić zmiany?' "$ER/wt.log")" -eq 2 ] \
   && grep -F 'Adres hosta: r1' "$ER/wt.log" | grep -F -e '--inputbox' | sed -n 2p | grep -qF '~ 10.99.0.9 ~' \
   && grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | sed -n 2p | grep -qE 'Źródło +pve9 \(192\.168\.28\.99\) -> 10\.99\.0\.9 \[zmiana\]'; then
    ok "edit-relation: Adres hosta -- zmiana czeka na liscie; Wstecz pyta o porzucenie, pole pamieta adres; Porzuc = nic nie uruchomione"
else
    bad "edit-relation: Adres hosta -- Wstecz" "rc=$ERRC" "$(cat "$ER/zb.log")"
fi
# E-2 (kampania na zywo, pve10 2026-10-21): adres, pod ktorym nic nie odpowiada, NIE trafia na
# liste zmian -- okno mowi o tym od razu, zadnego activate (wczesniej activate zapisywal go w
# rekordzie jako endpoint_change_pending i padal z komunikatem o pliku zakresu).
EROUT=$(ER_PROBE=false er_run "0${T}adres
0${T}192.168.28.250
0${T}
1${T}
1${T}
0${T}
"); ERRC=$?
if ! grep -q '^activate' "$ER/zb.log" && grep -qF 'nic nie odpowiada' "$ER/wt.log" && grep -qF 'NIE został zmieniony' "$ER/wt.log" \
   && ! grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | grep -qF '192.168.28.250 [zmiana]'; then
    ok "edit-relation: E-2 -- adres bez odpowiedzi: komunikat od razu, nie ma go na liscie zmian, zadnego activate"
else
    bad "edit-relation: E-2 adres bez odpowiedzi" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(grep -F 'odpowiada' "$ER/wt.log" | cut -c1-200)"
fi
# Zly znak w adresie: komunikat, zadnego activate.
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9;id
0${T}
1${T}
1${T}
"); ERRC=$?
if ! grep -q '^activate' "$ER/zb.log" && grep -qF 'Zły adres' "$ER/wt.log"; then
    ok "edit-relation: Adres hosta -- adres ze zlym znakiem odrzucony, nic nie uruchomione"
else
    bad "edit-relation: Adres hosta -- zly znak" "rc=$ERRC" "$(cat "$ER/zb.log")"
fi
# Zmiana adresu w toku (literowka, verify-endpoint odmowil): okno otwiera sie prosto na polu,
# z zapisanym (niesprawdzonym) adresem -- poprawka tym samym oknem.
EROUT=$(ER_STATE=endpoint_change_pending ER_EP=10.99.0.99:22 er_run "0${T}10.99.0.9
0${T}
"); ERRC=$?
ERA="$(head -2 "$ER/wt.log" | grep -F -e '--inputbox' | head -1)"
if [ "$ERRC" -eq 0 ] && grep -qx 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes' "$ER/zb.log" \
   && has "$ERA" 'Zapisany: 10.99.0.99:22' && ! grep -qF 'Co zmienić?' "$ER/wt.log"; then
    ok "edit-relation: zmiana adresu w toku -- okno prosto na polu adresu, poprawka tym samym activate"
else
    bad "edit-relation: zmiana adresu w toku" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(head -3 "$ER/wt.log" | cut -c1-250)"
fi
# Nowy adres nie odpowiedzial: verify wrocil do starego, activate stanal przed instalacja
# -- relacja jest endpoint_verified (zmierzone na pve10, 2026-10-17). Okno tez prosto na polu.
EROUT=$(ER_STATE=endpoint_verified er_run "0${T}10.99.0.9
0${T}
"); ERRC=$?
if [ "$ERRC" -eq 0 ] && grep -qx 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes' "$ER/zb.log" \
   && ! grep -qF 'Co zmienić?' "$ER/wt.log" && ! grep -qF 'Nie da się zmienić' "$ER/wt.log"; then
    ok "edit-relation: po nieudanej zmianie adresu (endpoint_verified) okno prosto na polu adresu"
else
    bad "edit-relation: endpoint_verified -> pole adresu" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(head -3 "$ER/wt.log" | cut -c1-250)"
fi
# Relacja lokalna (bez peera): na karcie NIE ma wiersza "Źródło" (tag adres).
EROUT=$(ER_PEER= er_run "1${T}
"); ERRC=$?
if grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF 'nazwa r1   konto root' \
   && ! grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF 'Źródło' \
   && ! grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF ' ~ adres ~ '; then
    ok "edit-relation: relacja lokalna -- karta bez wiersza Źródło (adres)"
else
    bad "edit-relation: relacja lokalna bez Adres hosta" "$(grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | cut -c1-400)"
fi
# U65 (makieta 2026-10-21): to, czego sie nie zmienia (rodzaj, nazwa, konto, cel), stoi w NAGLOWKU
# karty, nie na liscie; na liscie tylko zmienialne, pod kreska tylko zapis (bez Kopii teraz,
# recznej edycji i szablonu -- te sa w oknie relacji na F3: F7, 'c', 's').
EROUT=$(er_run "1${T}
"); ERRC=$?
ERC1="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | head -1)"
if [ "$ERRC" -eq 1 ] && has "$ERC1" 'backup z pve9   nazwa r1   konto root   cel ' \
   && ! has "$ERC1" ' ~ rodzaj ~ ' && ! has "$ERC1" ' ~ cel ~ ' && ! has "$ERC1" ' ~ nazwa ~ ' && ! has "$ERC1" ' ~ konto ~ ' \
   && ! has "$ERC1" ' ~ teraz ~ ' && ! has "$ERC1" ' ~ config ~ ' && ! has "$ERC1" ' ~ zapisz ~ ' \
   && has "$ERC1" ' ~ wykonaj ~ Zapisz zmiany (brak zmian)' && hasE "$ERC1" ' ~ dane ~   Datasety +'    && ! has "$ERC1" 'jak w configu' && hasE "$ERC1" 'Silnik +(fabryczne|historia|kompresja|szyfr|autodobór|raw)'    && hasE "$ERC1" 'Retencja źródła +(tyle samo co w kopii|godzinowe|dobowe|tygodniowe|miesięczne|roczne|[A-Za-z0-9])'; then
    ok "edit-relation: karta U65 -- stale fakty w naglowku, na liscie tylko zmienialne (wartosci slowami, nie jak w configu), pod kreska tylko Zapisz zmiany"
else
    bad "edit-relation: karta U65" "rc=$ERRC" "$(printf '%s' "$ERC1" | cut -c1-700)"
fi
# Retencja zrodla na karcie = liczby z CONFIGU (show-tiers), nie nazwa profilu zrodla: na pve10
# zmiana tabela (set-tiers 168 -> 72) zostawila "tyle samo co w kopii" (2026-10-22).
EROUT=$(ER_SRC_KEEP=72 er_run "1${T}
"); ERK1="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | head -1)"
EROUT=$(er_run "1${T}
"); ERK2="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | head -1)"
if hasE "$ERK1" 'Retencja źródła +godzinowe 72, dobowe 7 ~' && hasE "$ERK2" 'Retencja źródła +tyle samo co w kopii ~'; then
    ok "edit-relation: karta -- retencja zrodla z configu (godzinowe 72, dobowe 7), rowna celowi = 'tyle samo co w kopii'"
else
    bad "edit-relation: retencja zrodla na karcie" "$(printf '%s' "$ERK1" | grep -o 'Retencja[^~]*')" "$(printf '%s' "$ERK2" | grep -o 'Retencja[^~]*')"
fi
# REV-20261023-171: rownosc = OBA zbiory szczebli z retencja takie same. Porownanie szlo tylko
# po szczeblach zrodla, wiec zrodlo bez dobowego (set-tiers --drop-src-tier=daily) mowilo
# "tyle samo co w kopii". Ten sam formatter co w produkcji (wyciety z edit-relation.sh).
SRF="$(mktemp -d)"
sed -n '/^srcret_words()/,/^sargs_words()/p' "$REPO/tui/edit-relation.sh" \
    | awk '/^import json, sys/{c=1} c && /^PYEOF$/{exit} c{print}' > "$SRF/f.py"
srf() {   # <target tiers> <source tiers>, each "name:keep,..." -> formatter output
    "$PY" - "$1" "$2" > "$SRF/t.json" <<'PYEOF'
import json, sys
def side(s): return [{"name": p.split(":")[0], "keep": p.split(":")[1], "retain": ""} for p in s.split(",") if p]
json.dump({"target": side(sys.argv[1]), "source": side(sys.argv[2])}, sys.stdout)
PYEOF
    "$PY" "$SRF/f.py" "$SRF/t.json" | tr -d '\r'
}
sr_eq="$(srf hourly:24,daily:7 hourly:24,daily:7)"; sr_val="$(srf hourly:24,daily:7 hourly:12,daily:7)"
sr_miss="$(srf hourly:24,daily:7 hourly:24)"; sr_extra="$(srf hourly:24 hourly:24,daily:7)"; sr_empty="$(srf hourly:24,daily:7 '')"; sr_none="$(srf '' '')"
if [ "$sr_eq" = "tyle samo co w kopii" ] && [ "$sr_val" = "godzinowe 12, dobowe 7" ] && [ "$sr_miss" = "godzinowe 24" ] \
   && [ "$sr_extra" = "godzinowe 24, dobowe 7" ] && [ "$sr_empty" = "bez retencji (źródło nie przycina migawek)" ]    && [ "$sr_none" = "tyle samo co w kopii" ]; then
    ok "edit-relation: karta -- retencja zrodla rowna celowi tylko przy identycznych zbiorach szczebli (REV-171: brak, nadmiar, inna liczba, puste zrodlo; dwie puste strony = rowne)"
else
    bad "edit-relation: karta -- rownosc retencji zrodla (REV-171)" "eq=[$sr_eq] val=[$sr_val] miss=[$sr_miss] extra=[$sr_extra] empty=[$sr_empty] none=[$sr_none]"
fi
rm -rf "$SRF"
# Zmieniona pozycja ma '*' (i [zmiana]); niezmieniona -- dwie spacje.
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9
1${T}
0${T}
"); ERRC=$?
ERC2="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | sed -n 2p)"
if has "$ERC2" ' ~ adres ~ * Źródło' && has "$ERC2" ' ~ dane ~   Datasety' && has "$ERC2" 'ZAPISZ ZMIANY (1)'; then
    ok "edit-relation: karta U65 -- zmieniona pozycja z gwiazdka, licznik w ZAPISZ ZMIANY (1)"
else
    bad "edit-relation: gwiazdka przy zmianie" "rc=$ERRC" "$(printf '%s' "$ERC2" | cut -c1-600)"
fi
# U25: "Harmonogram" (tag harmon) otwiera liste szablonow, a jej PIERWSZA pozycja to __manual__ (Ręcznie…).
EROUT=$(er_run "0${T}harmon
1${T}
"); ERRC=$?
ERLST="$(grep -F 'użyj szablonu' "$ER/wt.log" | grep -F -e '--menu' | head -1)"
if hasE "$ERLST" '--menu ~ [^~]* ~ [0-9]+ ~ [0-9]+ ~ [0-9]+ ~ __manual__ ~'; then
    ok "edit-relation: karta -- Harmonogram otwiera liste szablonow z __manual__ (Ręcznie…) jako PIERWSZA pozycja"
else
    bad "edit-relation: karta, lista szablonow bez __manual__ na gorze" "rc=$ERRC" "$(printf '%s' "$ERLST" | cut -c1-500)"
fi
# U65: 'c' w oknie relacji (EDIT_DO=config) = od razu edit-config, bez karty zmian.
EROUT=$(EDIT_DO=config er_run ""); ERRC=$?
if grep -qx 'edit-config r1' "$ER/zb.log" && ! grep -qF 'Co zmienić?' "$ER/wt.log"; then
    ok "edit-relation: EDIT_DO=config -- od razu edit-config, karta zmian sie nie pokazuje (U65, 'c' na F3)"
else
    bad "edit-relation: EDIT_DO=config" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(head -2 "$ER/wt.log" | cut -c1-200)"
fi
# U38 (wlasciciel 2026-10-20, "cos w stylu mc, z widokiem migawek"): okno migawek pary.
# Ksztalt danych jak z prawdziwego pair-snapshots na pve10 (ab, hdd/data): wyrownanie po GUID,
# baza = NAJNOWSZA wspolna (blad z pierwszej jazdy: brana byla najstarsza), '>' tylko nowsze
# niz baza (replica_ starsza tylko u zrodla -- bez znaku), dwa panele mieszcza sie w szerokosci,
# wezej -- jeden panel i Tab.
U38="$("$PY" - "$TUI" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("zt", sys.argv[1]); zt = importlib.util.module_from_spec(spec); spec.loader.exec_module(zt)
S = lambda n, g, c: {"snap": n, "guid": g, "creation": c, "used": 0, "holds": 0}
d = {"source": {"dataset": "hdd/data", "host": "10.98.0.2", "snapshots": [S("automated_daily_1", "g1", 100), S("replica_x", "gr", 150),
        S("automated_hourly_2", "g2", 200), S("automated_hourly_3", "g3", 300)], "bookmarks": []},
     "target": {"dataset": "hdd/backups/h/hdd/data", "snapshots": [S("automated_daily_1", "g1", 100), S("automated_hourly_2", "g2", 200)]}}
rows = zt.snap_pair_rows(d)
print("MARKS", "".join(m for m, s, t in rows))
print("SUM", zt.snap_pair_summary(d, rows))
wide = zt.snap_pair_lines(d, 160, 0, 400)
print("WIDE", max(len(l) for l in wide) <= 156, any(u"│" in l for l in wide))
narrow = zt.snap_pair_lines(d, 100, 1, 400)
print("NARROW", any(u"KOPIA" in l for l in narrow), not any(u"│" in l for l in narrow))
PYEOF
)"
if has "$U38" 'MARKS = =>' && has "$U38" 'Baza następnej kopii: hourly_2' && has "$U38" 'do skopiowania: 1' \
   && has "$U38" 'WIDE True True' && has "$U38" 'NARROW True True'; then
    ok "migawki pary (U38): wyrownanie po GUID, baza = najnowsza wspolna, '>' tylko nowsze niz baza, dwa panele w szerokosci, wezej jeden"
else
    bad "migawki pary (U38)" "$U38"
fi
# Stan strażników hosta na pasku (wlasciciel 2026-10-21): to samo zrodlo co skrypty w cronie --
# settings.ini (F10), gdy klucza brak -- stary zfs-alert.conf, domyslnie wyl.; ciasno -- odpada.
GT="$("$PY" - "$TUI" <<'PYEOF'
import importlib.util, sys, tempfile, os
spec = importlib.util.spec_from_file_location("zt", sys.argv[1]); zt = importlib.util.module_from_spec(spec); spec.loader.exec_module(zt)
d = tempfile.mkdtemp()
si = os.path.join(d, "settings.ini"); cf = os.path.join(d, "zfs-alert.conf")
open(si, "w").write("[capacity]\nguard = on\n"); open(cf, "w").write("ZFS_GROWTH_ALERT=on\nZFS_GUARD=off\n")
print("A", zt.guard_states(si, [cf]))
open(si, "w").write("[capacity]\nguard = off\n[growth]\nalert = off\n"); open(cf, "w").write("ZFS_GUARD=on\nZFS_GROWTH_ALERT=on\n")
print("B", zt.guard_states(si, [cf]))
print("C", zt.guard_states(os.path.join(d, "brak.ini"), [os.path.join(d, "brak.conf")]))
class D: pass
x = D(); x.jobs = {"host": "pve10", "jobs": [{"account": "root"}]}; x.read_at = 0; x.host_ip = None; x.guards = ("on", "off")
print("WIDE", u"kasowanie przy pełnej puli: wł. · alarm przyrostu: wył." in zt.top_bar(x, 140, 0, False, 0))
print("NARROW", u"pełnej puli" not in zt.top_bar(x, 70, 0, False, 0), len(zt.top_bar(x, 70, 0, False, 0)) <= 70)
w = zt.top_bar(x, 200, 0, False, 0)
print("CREDIT", u"by Wojciech Król (Adalbert King)" in w and u"pełnej puli" in w and len(w) <= 200, u"Król" not in zt.top_bar(x, 80, 0, False, 0))
PYEOF
)"
if has "$GT" "A ('on', 'on')" && has "$GT" "B ('off', 'off')" && has "$GT" "C ('off', 'off')" && has "$GT" 'WIDE True' && has "$GT" 'NARROW True True' && has "$GT" 'CREDIT True True'; then
    ok "pasek: stan straznikow hosta -- F10 przed starym conf, F10 wyl. wygrywa z conf wl., brak plikow = wyl.; waski pasek pomija; autor tylko przy zapasie miejsca"
else
    bad "pasek: stan straznikow" "$GT"
fi
# CONFIG JAKO JEDYNE ZRODLO (wlasciciel 2026-10-13): "Retencja zrodla" (tag srcret, U25) czyta
# szczeble z configu (show-tiers) i zapisuje JEDNYM set-tiers -- bez ukrytego szablonu (zadnego
# save-profile, delete-profile ani edit-relation). Zrodlo hourly 24 -> 12 w oknie zrodla =
# --src-tier. Samo okno zrodla: jedno wywolanie tabeli (jedna linia klawiszy), bez tabeli celu.
EROUT=$(er_run "0${T}srcret
0${T}wykonaj
0${T}
" "right,bs,bs,1,2,enter"); ERRC=$?
if [ "$ERRC" -eq 0 ] && grep -qx 'show-tiers r1 --json' "$ER/zb.log" \
   && grep -qx 'set-tiers r1 --src-tier=hourly --keep=12 --plan' "$ER/zb.log" && grep -qx 'set-tiers r1 --src-tier=hourly --keep=12 --yes' "$ER/zb.log" \
   && ! grep -qE '^(save-profile|delete-profile|edit-relation)' "$ER/zb.log" \
   && [ "$(cat "$ER/grid.n")" = 1 ] \
   && grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qE 'Datasety +1'; then
    ok "edit-relation: Retencja zrodla (srcret) -- szczeble z configu (show-tiers), jedna tabela (zrodlo), jeden set-tiers --plan, WYKONAJ = --yes; bez ukrytego szablonu"
else
    bad "edit-relation: harmonogram przez set-tiers" "rc=$ERRC" "$(cat "$ER/zb.log")" "grid.n=$(cat "$ER/grid.n" 2>/dev/null)" "$(tail -3 "$ER/err")"
fi
# X20 (wlasciciel 2026-10-14): tabela celu (harmon -> __manual__) otwarta DRUGI raz pokazuje
# WPISANA zmiane (dobowe 5), nie znow wartosc z configu (7); zmiana idzie do set-tiers raz.
EROUT=$(er_run "0${T}harmon
0${T}__manual__
0${T}harmon
0${T}__manual__
0${T}wykonaj
0${T}
" "down,down,right,bs,5,enter\nenter"); ERRC=$?
ERT2=$(printf '%s' "$EROUT" | awk '/Harmonogram i retencja: W CELU KOPII/{n++} n==2' | grep -E '\] dobowe')
if [ "$ERRC" -eq 0 ] && printf '%s' "$ERT2" | grep -qE '\[X\] dobowe +5 ' && grep -qx 'set-tiers r1 --tier=daily --keep=5 --yes' "$ER/zb.log" \
   && [ "$(grep -c '^set-tiers .*--yes$' "$ER/zb.log")" -eq 1 ]; then
    ok "edit-relation: X20 -- tabela celu otwarta drugi raz pamieta wpisana zmiane (dobowe 5), set-tiers dostaje ja raz"
else
    bad "edit-relation: X20 zmiana w tabeli celu po ponownym otwarciu" "rc=$ERRC" "druga tabela: $ERT2" "$(grep '^set-tiers' "$ER/zb.log")"
fi
# X15 (wlasciciel 2026-10-13): szczebel DODANY w tabeli celu (harmon -> __manual__) jest w oknie
# zrodla (srcret, z liczba jak w celu) -- okno zrodla widzi szczeble po zmianach w celu.
# set-tiers dostaje dodanie i liczbe zrodla tego szczebla, bez drugiego dodawania.
EROUT=$(er_run "0${T}harmon
0${T}__manual__
0${T}srcret
0${T}wykonaj
0${T}
" "down,down,down,space,enter\nenter"); ERRC=$?
ERSRC=$(printf '%s' "$EROUT" | sed -n '/Retencja: W ŹRÓDLE KOPII/,$p')
if [ "$ERRC" -eq 0 ] && printf '%s' "$ERSRC" | grep -q 'tygodniowe' \
   && grep -qx 'set-tiers r1 --add-tier=weekly --src-tier=weekly --keep=4 --yes' "$ER/zb.log" && ! grep -q -- '--add-src-tier' "$ER/zb.log"; then
    ok "edit-relation: X15 -- szczebel dodany w celu (tygodniowe) jest w oknie zrodla; set-tiers --add-tier + --src-tier, bez podwojnego dodania"
else
    bad "edit-relation: X15 nowy szczebel w oknie zrodla" "rc=$ERRC" "$(grep '^set-tiers' "$ER/zb.log")" "$(printf '%s' "$ERSRC" | grep -E 'godzin|dobow|tygod')"
fi
# Zmiana retencji zrodla (srcret) sprawdzona planem i czeka na liscie; Wstecz z planu WYKONAJ
# wraca na karte, Wstecz z karty + Porzuc = nic nie zainstalowane, zadnego pliku szablonu.
EROUT=$(er_run "0${T}srcret
0${T}wykonaj
1${T}
1${T}
0${T}
" "right,bs,bs,1,2,enter"); ERRC=$?
ERT=$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Zmiana relacji r1 ~' | sed -n 2p)
if [ "$ERRC" -eq 1 ] && grep -qx 'set-tiers r1 --src-tier=hourly --keep=12 --plan' "$ER/zb.log" \
   && ! grep -q -- '--yes$' <(grep '^set-tiers' "$ER/zb.log") && ! grep -qE '^(save-profile|delete-profile)' "$ER/zb.log" \
   && hasE "$ERT" 'Retencja źródła +[^~]*-> godzinowe 12 \[zmiana\]' && has "$ERT" 'ZAPISZ ZMIANY (1)'; then
    ok "edit-relation: zmiana retencji zrodla czeka na liscie ([zmiana], Zapisz zmiany (1)); Wstecz z planu i Porzuc -- nic nie zainstalowane"
else
    bad "edit-relation: Wstecz z planu (set-tiers)" "rc=$ERRC" "okna: $ERT" "$(cat "$ER/zb.log")"
fi
# X5 (wlasciciel 2026-10-12): Wstecz z PLANU = jeden krok -- wraca do okna retencji
# ZRODLA, nie do wyboru szablonu. Szablon d30h24 ma szczeble, wiec okno zrodla jest:
# po Wstecz z planu pokazuje sie DRUGI raz (przed poprawka -- raz, bo plan wracal do
# listy szablonow). Esc tam = dopiero teraz wstecz do listy.
EROUT=$(er_run "0${T}harmon
0${T}d30h24
0${T}
1${T}
" "esc"); ERRC=$?
ERT=$(printf '%s' "$EROUT" | grep -oE 'Harmonogram i retencja: W CELU KOPII|Retencja: W ŹRÓDLE KOPII' | tr '\n' '|')
if [ "$ERT" = 'Retencja: W ŹRÓDLE KOPII|' ] && [ "$(grep -cF 'użyj szablonu' "$ER/wt.log")" -eq 2 ] && ! grep -q '^edit-relation r1 --profile=d30h24' "$ER/zb.log"; then
    ok "edit-relation: X5 -- Wstecz z okna retencji zrodla = jeden krok, do listy szablonow; nic nie liczone"
else
    bad "edit-relation: X5 Wstecz z planu" "kolejnosc okien: $ERT" "$(cat "$ER/zb.log")"
fi
EROUT=$(er_run "0${T}harmon
0${T}d30h24
0${T}
0${T}wykonaj
0${T}
" "right,bs,bs,1,2,enter"); ERRC=$?
# X27 etap B (wlasciciel 2026-10-14): szablon i liczby zrodla JEDNYM zapisem -- jedno
# edit-relation z --src-tier (bez pochodnego szablonu i bez drugiego kroku set-tiers).
if [ "$ERRC" -eq 0 ] && ! grep -q '^save-profile' "$ER/zb.log" \
   && grep -qx 'edit-relation r1 --profile=d30h24 --source-profile= --src-tier=hourly --keep=12 --yes' "$ER/zb.log" \
   && ! grep -q '^set-tiers' "$ER/zb.log" \
   && ! grep -qF 'Krok 2 -- liczby u źródła' "$ER/wt.log" && ! grep -qF '2/2 retencja na źródle' "$ER/wt.log"; then
    ok "edit-relation: Uzyj szablonu -> szablon i liczby zrodla JEDNYM edit-relation (X27 B: bez drugiego kroku set-tiers); to samo okno-tabela zrodla"
else
    bad "edit-relation: szablon + retencja zrodla" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(tail -3 "$ER/err")"
fi
# X24 (wlasciciel 2026-10-14): szablon NADPISUJE liczby zrodla -- przed oknem zrodla okno
# ostrzezenia z roznica (zrodlo w configu: dobowe 7, d30h24 da 30; godzinowe 24 = 24, bez
# wiersza), a plan powtarza ostrzezenie, gdy w oknie zrodla nic nie zmieniono.
EROUT=$(er_run "0${T}harmon
0${T}d30h24
0${T}
0${T}wykonaj
1${T}
" "enter"); ERRC=$?
ERW=$(cat "$ER/wt.log")
if has "$ERW" 'Uwaga: szablon nadpisze liczby w źródle' && has "$ERW" 'dobowe      źródło trzyma 7, szablon da 30' \
   && ! has "$ERW" 'godzinowe   źródło trzyma' && has "$ERW" 'UWAGA -- źródło dostanie liczby szablonu'; then
    ok "edit-relation: X24 -- Uzyj szablonu ostrzega, ze nadpisze liczby zrodla (dobowe 7 -> 30), plan to powtarza"
else
    bad "edit-relation: X24 ostrzezenie" "rc=$ERRC" "$(grep -F 'nadpisze' "$ER/wt.log" | cut -c1-300)" "$(tail -3 "$ER/err")"
fi
# U65: 's' w oknie relacji (EDIT_DO=zapisz) = od razu "Zapisz jako szablon"; po nim koniec, bez karty.
EROUT=$(EDIT_DO=zapisz er_run "0${T}r1-szablon
0${T}
"); ERRC=$?
if [ "$ERRC" -eq 0 ] && grep -q '^save-profile --from=d7h24 --as=r1-szablon --description=Ustawienia relacji r1$' "$ER/zb.log" && ! grep -q -- '--hidden' "$ER/zb.log" \
   && ! grep -qF 'Co zmienić?' "$ER/wt.log"; then
    ok "edit-relation: EDIT_DO=zapisz -- zwykly szablon (bez --hidden), widoczny na F5; karta zmian sie nie pokazuje (U65, 's' na F3)"
else
    bad "edit-relation: zapisz jako szablon" "rc=$ERRC" "$(cat "$ER/zb.log")"
fi
# Kampania 2026-10-22: szablon z inna rodzina migawek (czasownik: "is a NEW relationship") --
# po odmowie z powrotem LISTA szablonow, nie ostrzezenie/tabela (petla bez wyjscia).
EROUT=$(ER_NEWREL=1 er_run "0${T}harmon
0${T}d30h24
0${T}
0${T}
1${T}
1${T}
" "enter"); ERRC=$?
if grep -o -e '--title ~ [^~]*' "$ER/wt.log" | tr '\n' ';' | grep -qF 'odmówił -- nic nie zmieniono ;--title ~ Zmień relację r1 -- użyj szablonu' \
   && grep -q -- '^edit-relation r1 --profile=d30h24 .*--plan$' "$ER/zb.log" \
   && ! grep -qE '^edit-relation .*--yes' "$ER/zb.log"; then
    ok "edit-relation: odmowa 'NOWA relacja' po wyborze szablonu wraca do listy szablonow (nie w kolko ostrzezenie -> tabela)"
else
    bad "edit-relation: odmowa NEW relationship" "rc=$ERRC" "$(grep -o -e '--title ~ [^~]*' "$ER/wt.log" | tr '\n' ';')"
fi
# X6 (wlasciciel 2026-10-12): reczna zmiana configu relacji -- plan mowi to na GORZE,
# zanim WYKONAJ ja nadpisze; bez recznych zmian ostrzezenia nie ma (kontrola).
EROUT=$(ER_HAND=1 er_run "0${T}harmon
0${T}d30h24
0${T}
0${T}wykonaj
1${T}
" "enter"); ERRC=$?
ERP=$(cat "$ER/wt.log")
EROUT=$(er_run "0${T}harmon
0${T}d30h24
0${T}
0${T}wykonaj
1${T}
" "enter")
ERP0=$(cat "$ER/wt.log")
if has "$ERP" 'UWAGA: relacja ma ustawienia inne niż jej szablon' && has "$ERP" 'dobowe, godzina sprzątania:  29 1 * * * -> 31 1 * * *' \
   && has "$ERP" 'zamiast zmieniać szablon' && ! has "$ERP0" 'inne niż jej szablon'; then
    ok "edit-relation: X6 -- reczna zmiana configu (29 -> 31) na gorze planu przed WYKONAJ; bez recznych zmian -- bez ostrzezenia"
else
    bad "edit-relation: X6 ostrzezenie o recznej zmianie" "$(printf '%s' "$ERP" | cut -c1-400)" "$(printf '%s' "$ERP0" | cut -c1-200)"
fi
# hand-edits.py wprost, postac LOKALNA (pelny kandydat + plik configu): zmienione pole
# zgloszone; wyjatek, ktory czasownik sam zdjal (">>> exception ... dropped"), nie jest
# reczna zmiana; sekcja spoza planu (inna relacja) pominieta; brak roznic = pusto.
HE="$(mktemp -d)"
printf '[template:profile__relacja-r1__lsrc_daily]\n\tprune_schedule = 29 1 * * *\n[dataset:hdd/ct]\n\texclude_child_1 = ^hdd/vms/vm3$\n\tpair_label = r1\n[dataset:other]\n\tpair_label = r2\n' > "$HE/c.conf"
{ echo ">>> exception '^hdd/vms/vm3\$' dropped -- no source of the relationship covers hdd/vms/vm3 any more"
  echo "  Target config:    $(cygpath -m "$HE/c.conf" 2>/dev/null || echo "$HE/c.conf") (istnieje)"
  echo "--- candidate CONFIG v4 (full: existing + new job) ---"
  printf '[template:profile__relacja-r1__lsrc_daily]\n\tprune_schedule = 31 1 * * *\n[dataset:hdd/ct]\n\tpair_label = r1\n'
  echo "--- generated cron block ---"; } > "$HE/plan.txt"
HE1="$("$PY" "$REPO/tui/hand-edits.py" "$HE/plan.txt" r1)"
sed -i 's/29 1/31 1/' "$HE/c.conf"; sed -i '/vm3/d' "$HE/c.conf"
HE2="$("$PY" "$REPO/tui/hand-edits.py" "$HE/plan.txt" r1)"
if has "$HE1" 'źródło, dobowe, godzina sprzątania:  29 1 * * * -> 31 1 * * *' && ! has "$HE1" 'wyjątek' && ! has "$HE1" 'other' && [ -z "$HE2" ]; then
    ok "hand-edits.py: postac lokalna -- zmienione pole zgloszone, wyjatek zdjety przez czasownik pominiety, inne relacje pominiete; bez roznic pusto"
else
    bad "hand-edits.py: postac lokalna" "$HE1" "po wyrownaniu: [$HE2]"
fi
rm -rf "$HE"
rm -rf "$ER"

# ============================================================================
# OKNO PRZYWRÓĆ (tui/restore.sh, C2a, 2026-10-15)
#
# Okno nie ma logiki odzysku: sklada JEDNO polecenie `zfs-backup.sh restore` z czterech
# odpowiedzi (co / z kiedy / dokad / sprawdz -- U109: z czego, potem dokad). Atrapa czasownika (zb) zapisuje argv
# kazdego wywolania innego niz --plan do RW/ran -- test porownuje dokladnie to, co
# dostalby prawdziwy czasownik. Atrapa whiptaila = ta sama co w kreatorze (kontrakt
# sterowania: odpowiedz na stderr, rc, znacznik musi byc na liscie). Drzewo (ZFS_TREE) to
# atrapa, ktora oddaje gotowy JSON z TREE_OUT; sam tree.py ma osobne testy.
# ============================================================================
RW="$(mktemp -d)"; mkdir -p "$RW/bin" "$RW/conf"
cp "$NR/bin/whiptail" "$RW/bin/whiptail"
: > "$RW/conf/jobs.h.conf"; : > "$RW/conf/jobs.h.zfsbackup.conf"
cat > "$RW/plan.json" <<'EOF'
{"config":"x","datasets":[{"source":"acct@10.0.0.9:hdd/data","relation":"k2","copy":"tank/b/hdd/data","copy_exists":true,"consistency":"ok","snapshots":[{"name":"automated_daily_2026-10-14_01-35-01","creation":1792020000,"guid":"1"},{"name":"automated_hourly_2026-10-15_17-25-01","creation":1792081503,"guid":"2"}]}]}
EOF
cat > "$RW/bin/zb" <<'EOF'
#!/bin/bash
if [ "$1" = restore ] && [ "$2" = --plan ]; then
    case " $* " in
        *" --config=$NR_DIR/conf/jobs.h.zfsbackup.conf "*) cat "$NR_DIR/plan.json" ;;
        *) echo '{"config":"x","datasets":[]}' ;;
    esac
    exit 0
fi
# U14: `restore NAZWA --grant` -- odpowiedz celu o zgode (domyslnie: jest create rewind).
if [ "$1" = restore ] && case " $* " in *" --grant "*) true ;; *) false ;; esac; then
    printf '%b\n' "${STUB_GRANT_OUT:-HOST=10.0.0.9\nLABEL=pve9\nGRANT=create rewind}"
    exit "${STUB_GRANT_RC:-0}"
fi
if [ "$1" = restore ]; then
    line=""; for a in "$@"; do line="${line:+$line ~ }$a"; done
    printf '%s\n' "$line" >> "$NR_DIR/ran"
    echo "RESTORE-STUB OK"; exit 0
fi
exit 9
EOF
cat > "$RW/bin/zfs" <<'EOF'
#!/bin/bash
case "$*" in
    "list -H -p -o name,used,type -r tank/b/hdd/data")
        printf 'tank/b/hdd/data\t3000\tfilesystem\ntank/b/hdd/data/docs\t1000\tfilesystem\ntank/b/hdd/data/mail\t2000\tfilesystem\n'
        exit 0 ;;
    "list -H -p -o name,used,type")      # tryb --from-copy: wszystkie datasety hosta, bez -r
        for d in usb9 usb9/backups usb9/backups/192.168.28.98 usb9/backups/192.168.28.98/hdd/data usb9/backups/192.168.28.98/hdd/data/docs usb9/replica/hdd/data/docs usb9/replica/tank/x hdd hdd/data hdd/foo/bar tank/b/hdd/data; do
            printf '%s\t1000\tfilesystem\n' "$d"
        done
        exit 0 ;;
    "list -H -o name -- "*)              # istnieje: hdd/data i wszystko z usb9
        case "$6" in hdd/data|usb9*) echo "$6"; exit 0 ;; *) exit 1 ;; esac ;;
    "list -H -p -t snapshot -o name,creation -s creation -d 1 -- "*)   # od najstarszej; $13 = dataset
        printf '%s@automated_daily_2026-10-14_01-35-01\t1792020000\n%s@automated_hourly_2026-10-15_17-25-01\t1792081503\n' "${13}" "${13}"
        exit 0 ;;
esac
exit 9
EOF
cat > "$RW/bin/tree" <<'EOF'
#!/bin/bash
out=""; spec=""; while [ $# -gt 0 ]; do [ "$1" = --out ] && out="$2"; [ "$1" = --spec ] && spec="$2"; shift; done
[ -n "$spec" ] && cp "$spec" "$NR_DIR/last-spec.json"
cp "$TREE_OUT" "$out"
EOF
# zpool: P5 -- okno z dysku sprawdza, czy cel zaczyna sie od puli TEGO hosta (tu: hdd, usb9).
cat > "$RW/bin/zpool" <<'EOF'
#!/bin/bash
[ "$1" = list ] || exit 9
last="${!#}"
case "$last" in
    name) printf '%s\n' hdd usb9 ;;
    hdd|usb9) echo "$last" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$RW/bin/zb" "$RW/bin/zfs" "$RW/bin/tree" "$RW/bin/whiptail" "$RW/bin/zpool"
printf '{"action":"next","roots":["tank/b/hdd/data/docs"],"excl":{},"recursion":"flat"}\n' > "$RW/t-docs.json"
printf '{"action":"next","roots":["tank/b/hdd/data"],"excl":{},"recursion":"flat"}\n' > "$RW/t-whole.json"
printf '{"action":"next","roots":["tank/b/hdd/data"],"excl":{"tank/b/hdd/data":["tank/b/hdd/data/mail"]},"recursion":"flat"}\n' > "$RW/t-nomail.json"
RWCFG="$RW/conf/jobs.h.zfsbackup.conf"
rw_run() {   # <plik drzewa> -- odpowiedzi w $RW/answers; wynik: $RW/ran, $RW/wt.log, RW_RC
    rm -f "$RW/wt.n" "$RW/wt.log" "$RW/ran"
    ( export NR_DIR="$RW" WHIPTAIL="$RW/bin/whiptail" ZFS_BACKUP="$RW/bin/zb" ZFS_TREE="$RW/bin/tree" \
             ZFS_CONF_DIR="$RW/conf" PYTHON="$PY" PATH="$RW/bin:$PATH" TREE_OUT="$1"
      timeout 60 bash "$REPO/tui/restore.sh" k2 ) </dev/null >"$RW/out" 2>"$RW/err"
    RW_RC=$?
}
rw_ran() { cat "$RW/ran" 2>/dev/null; }

# 0b. W5 (kampania wariantow 2026-10-22): Wstecz z "Gdzie odtworzyc?" wraca do drzewa z TYM, co
#     admin zaznaczyl (docs), nie z cala relacja. Drugie wywolanie drzewa dostaje roots = docs.
printf '1\t\n0\tp0\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
if [ "$RW_RC" -eq 0 ] && grep -qF '"roots": ["tank/b/hdd/data/docs"]' "$RW/last-spec.json" 2>/dev/null \
   && has "$(rw_ran)" '--source=tank/b/hdd/data/docs '; then
    ok "restore: Wstecz z 'z kiedy?' (pierwsze okno po drzewie, U109) -> drzewo z ostatnim wyborem (docs), nie z cala relacja"
else
    bad "restore: Wstecz z 'Gdzie' gubi wybor" "rc=$RW_RC" "spec: $(cut -c1-300 "$RW/last-spec.json" 2>/dev/null)" "ran: $(rw_ran)"
fi

# 1. obok, tylko docs: config = ten, ktory MA wiersze (jobs.h.conf jest pierwszy w kolejnosci i pusty),
#    onto = baza/basename; bez --at (p0 = najnowszy), z --yes na koncu (okno podsumowania jest jedynym "Na pewno?",
#    wlasciciel 2026-10-29). Okno podsumowania ma "Wymaga zgody" i --defaultno.
printf '0\tp0\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
W1="restore ~ k2 ~ k2 ~ --source=tank/b/hdd/data/docs ~ --onto=hdd/restore/docs ~ --config=$RWCFG ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W1" ] && ! has "$(rw_ran)" '--at' && has "$(rw_ran)" '~ --yes'; then
    ok "restore: obok, tylko docs -> restore k2 k2 --source=docs --onto=hdd/restore/docs --config=<ten z wierszami> --yes, bez --at"
else
    bad "restore: obok, tylko docs" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W1" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi
RWSUM="$(grep -F -A 30 'k2: na pewno?' "$RW/wt.log" | head -40)"   # argv okna to jedna wielowierszowa pozycja dziennika
# U109 (wlasciciel 2026-10-28, symulacja A): najpierw z kiedy, potem dokad; lista punktow
# z pelna nazwa migawki; podsumowanie nazywa migawke, nie "Punkt: najnowszy".
RWKD="$(grep -n 'k2: z kiedy?' "$RW/wt.log" | head -1 | cut -d: -f1)"; RWDK="$(grep -n 'k2: dokąd?' "$RW/wt.log" | head -1 | cut -d: -f1)"
if [ -n "$RWKD" ] && [ -n "$RWDK" ] && [ "$RWKD" -lt "$RWDK" ] && grep -qE ' ~ p0 ~ 2026-10-1[56] [0-9]{2}:25:03  @automated_hourly_2026-10-15_17-25-01 ~ ' "$RW/wt.log" \
   && has "$RWSUM" 'Migawka: tank/b/hdd/data/docs@automated_hourly_2026-10-15_17-25-01' && ! has "$RWSUM" 'Punkt:  najnowszy'; then
    ok "restore U109: okno 'z kiedy' przed 'dokad', punkt = pelna nazwa migawki, podsumowanie 'Migawka: <dataset>@<nazwa>'"
else
    bad "restore U109: kolejnosc i nazwa migawki" "z kiedy=$RWKD dokad=$RWDK" "$(printf '%s' "$RWSUM" | head -12)"
fi
# U14: zgoda jest (atrapa: create rewind) -- podsumowanie mowi, jaka, i nie straszy brakiem.
# 2026-10-29: to okno jest jedynym "Na pewno?" -- przycisk Wykonaj i zdanie, ze polecenie idzie od razu (bez dalszych pytań).
if has "$RWSUM" 'Zgoda 10.0.0.9: create rewind' && has "$RWSUM" '--defaultno' && ! has "$RWSUM" 'Wymaga zgody' && ! grep -qF 'brak zgody' "$RW/wt.log" \
   && has "$RWSUM" '--yes-button ~ Wykonaj ~ --no-button ~ Wstecz' && has "$RWSUM" '<Wykonaj> uruchamia to od razu, bez dalszych pytań.'; then
    ok "restore: okno podsumowania ('na pewno?') ma domyslne 'Nie' (--defaultno), Wykonaj/Wstecz, zdanie 'uruchamia to od razu' i mowi, jaka zgode wydal cel (U14)"
else
    bad "restore: okno podsumowania" "$(printf '%s' "$RWSUM" | cut -c1-300)"
fi
# U14 (wlasciciel 2026-10-19): BRAK ZGODY mowi PIERWSZE okno, nie odmowa polecenia na koncu.
# g1: "Odtworz na tym hoscie" -> tryb --from-copy z wstepnie zaznaczona kopia; drzewo atrapy wraca
#     Wstecz, wiec nic nie uruchomione. g2: "Mimo to dalej" -> zwykle kroki, podsumowanie
#     "Wymaga zgody" z etykieta podana przez cel (pve9), nie z nazwy tego hosta.
printf '{"action":"back"}\n' > "$RW/t-back.json"
printf '0\ttutaj\n' > "$RW/answers"
STUB_GRANT_OUT='HOST=10.0.0.9\nLABEL=pve9\nGRANT=none' STUB_GRANT_RC=1 rw_run "$RW/t-back.json"
if grep -qF 'brak zgody na 10.0.0.9' "$RW/wt.log" && grep -qF 'deploy.sh --allow-restore=pve9' "$RW/wt.log" \
   && grep -qF '"roots": ["tank/b/hdd/data"]' "$RW/last-spec.json" 2>/dev/null && [ ! -e "$RW/ran" ]; then
    ok "restore: brak zgody celu -> pierwsze okno mowi to po polsku z poleceniem dla celu; 'na tym hoscie' otwiera tryb z kopii z ta kopia zaznaczona (U14)"
else
    bad "restore: brak zgody -- okno i 'na tym hoscie'" "rc=$RW_RC" "ran: $(rw_ran)" "wt: $(grep -c 'brak zgody' "$RW/wt.log") allow: $(grep -c 'allow-restore=pve9' "$RW/wt.log")" "roots: $(grep -o '"roots": [^]]*]' "$RW/last-spec.json" 2>/dev/null)" "err: $(cut -c1-200 "$RW/err")"
fi
printf '0\tdalej\n0\tp0\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
STUB_GRANT_OUT='HOST=10.0.0.9\nLABEL=pve9\nGRANT=none' STUB_GRANT_RC=1 rw_run "$RW/t-docs.json"
RWSUM_N="$(grep -F -A 30 'k2: na pewno?' "$RW/wt.log" | head -40)"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W1" ] && has "$RWSUM_N" 'Wymaga zgody na 10.0.0.9: deploy.sh --allow-restore=pve9'; then
    ok "restore: brak zgody + 'mimo to dalej' -> zwykle kroki i to samo polecenie; podsumowanie 'Wymaga zgody' z etykieta celu (U14)"
else
    bad "restore: brak zgody -- mimo to dalej" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W1" "sum: $(printf '%s' "$RWSUM_N" | grep -i zgod | cut -c1-200)"
fi
# g3: cel nie odpowiada (rc 2) -- inne zdanie, to samo okno.
printf '1\t\n' > "$RW/answers"
STUB_GRANT_OUT='HOST=10.0.0.9\nGRANT=unreachable' STUB_GRANT_RC=2 rw_run "$RW/t-docs.json"
if [ "$RW_RC" -ne 0 ] && grep -qF '10.0.0.9 nie odpowiedział na pytanie o zgodę' "$RW/wt.log" && [ ! -e "$RW/ran" ]; then
    ok "restore: cel nie odpowiada na pytanie o zgode -> okno to mowi; Wyjdz niczego nie uruchamia (U14)"
else
    bad "restore: cel nie odpowiada" "rc=$RW_RC" "ran: $(rw_ran)" "wt: $(tail -n 2 "$RW/wt.log" | cut -c1-200)"
fi
# 1b. RELACJA LOKALNA (zrodlo bez konto@host): to samo polecenie obok -- zfs-restore.sh przyjmuje je od
#     2026-10-17 (wczesniej FATAL "not one this host records") -- ale podsumowanie NIE kaze wydawac zgody:
#     restore jej dla celu na tym samym hoscie nie pyta. Kontrola: wariant zdalny wyzej ma "Wymaga zgody".
cp "$RW/plan.json" "$RW/plan.remote.json"
sed 's|"source":"acct@10.0.0.9:hdd/data"|"source":"hdd/data"|' "$RW/plan.remote.json" > "$RW/plan.json"
printf '0\tp0\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
RWSUM_L="$(grep -F -A 30 'k2: na pewno?' "$RW/wt.log" | head -40)"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W1" ] && has "$RWSUM_L" 'Relacja lokalna' && ! has "$RWSUM_L" 'Wymaga zgody'; then
    ok "restore: relacja lokalna obok -> to samo polecenie, podsumowanie bez zadania zgody"
else
    bad "restore: relacja lokalna obok" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W1" "sum: $(printf '%s' "$RWSUM_L" | grep -i -E 'zgod|lokaln' | cut -c1-200)"
fi
cp "$RW/plan.remote.json" "$RW/plan.json"

# Kampania marudnego admina (2026-10-28): wybral starsza migawke (p1), na "dokad" dal Wstecz --
# lista "z kiedy" wraca z kursorem na JEGO wyborze, nie na najnowszej.
printf '0\tp1\n1\t\n0\tp1\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
RWDI="$(grep -F 'k2: z kiedy?' "$RW/wt.log" | sed -n 2p)"
if [ "$RW_RC" -eq 0 ] && has "$RWDI" '--default-item ~ p1 ~' && has "$(rw_ran)" '--at='; then
    ok "restore: Wstecz z 'dokad' -> 'z kiedy' z kursorem na wybranej wczesniej migawce (p1), polecenie z --at"
else
    bad "restore: kursor po Wstecz" "rc=$RW_RC" "drugie okno: $(printf '%s' "$RWDI" | cut -c1-300)" "ran: $(rw_ran)"
fi

# 2. miejsce, cala relacja, punkt p1 (starszy): bez --source (WHOLE), bez --onto, z --at
printf '0\tp1\n0\tmiejsce\n0\t\n' > "$RW/answers"
rw_run "$RW/t-whole.json"
# --at dla punktu p1 = sekunda PRZED nowszym punktem p0 (P7, 2026-10-15): jeden bieg robi migawki
# datasetow sekundy po sobie, wiec sekunda migawki korzenia odcinala dzieci tego samego biegu.
RWAT="$(date -d @$((1792081503 - 1)) '+%Y-%m-%d %H:%M:%S')"
W2="restore ~ k2 ~ --at=$RWAT ~ --config=$RWCFG ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W2" ]; then
    ok "restore: na miejsce, cala relacja, punkt p1 -> restore k2 --at=<czas p1> --config=... (bez --source, bez --onto)"
else
    bad "restore: na miejsce, cala relacja" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W2" "err: $(cut -c1-200 "$RW/err")"
fi

# 3. miejsce z wylaczonym mail: nie cala relacja -> --source z lista (rodzice przed dziecmi)
printf '0\tp0\n0\tmiejsce\n0\t\n' > "$RW/answers"
rw_run "$RW/t-nomail.json"
W3="restore ~ k2 ~ --source=tank/b/hdd/data,tank/b/hdd/data/docs ~ --config=$RWCFG ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W3" ]; then
    ok "restore: na miejsce z wylaczonym mail -> --source=data,data/docs (WHOLE=0 dodaje --source)"
else
    bad "restore: na miejsce bez mail" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W3" "err: $(cut -c1-200 "$RW/err")"
fi

# 4. obok, cala relacja: --source i --onto w tej samej kolejnosci, onto = baza/data/...
printf '0\tp0\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-whole.json"
W4="restore ~ k2 ~ k2 ~ --source=tank/b/hdd/data,tank/b/hdd/data/docs,tank/b/hdd/data/mail ~ --onto=hdd/restore/data,hdd/restore/data/docs,hdd/restore/data/mail ~ --config=$RWCFG ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W4" ]; then
    ok "restore: obok, cala relacja -> --source=3 datasety, --onto=hdd/restore/data/... w tej samej kolejnosci"
else
    bad "restore: obok, cala relacja" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W4" "err: $(cut -c1-200 "$RW/err")"
fi

# 5. Wstecz z podsumowania wraca do punktow i NIC nie uruchamia: summary rc 1, punkty znowu, summary rc 0 -> JEDNA linia ran
printf '0\tp0\n0\tobok\n0\thdd/restore\n1\t\n0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran | grep -c '')" -eq 1 ] && [ "$(grep 'k2: na pewno?' "$RW/wt.log" | grep -c -- '--yesno')" -eq 2 ]; then
    ok "restore: Wstecz z podsumowania (wraca do 'dokad', U109) nic nie uruchamia -- dwa razy okno 'na pewno?', JEDNO wywolanie czasownika"
else
    bad "restore: Wstecz z podsumowania" "rc=$RW_RC" "ran: $(rw_ran)" "na pewno?: $(grep -c 'k2: na pewno?' "$RW/wt.log")"
fi

# 7. brak kopii na tym hoscie (oba configi bez wierszy): komunikat, exit 1, zero wywolan restore
echo '{"config":"x","datasets":[]}' > "$RW/plan.json"
printf '0\t\n' > "$RW/answers"
rw_run "$RW/t-whole.json"
if [ "$RW_RC" -eq 1 ] && [ ! -e "$RW/ran" ] && grep -qF 'Nie ma kopii relacji k2' "$RW/wt.log"; then
    ok "restore: relacja bez kopii na tym hoscie -> 'Nie ma kopii relacji k2', exit 1, czasownik nie uruchomiony"
else
    bad "restore: brak kopii" "rc=$RW_RC" "ran: $(rw_ran)" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi

# ---- tryb "Przywroc z dysku" (restore.sh --from-copy, C2b) -----------------------------------
# Jedno polecenie: restore --from-copy=.. --onto=.. [--at=..] [--with-history] [--overwrite] --yes
# (okno podsumowania jest jedynym "Na pewno?", wlasciciel 2026-10-29); nigdy --config. Atrapa zfs odpowiada na liste wszystkich datasetow hosta
# (usb9/..., hdd, hdd/data, hdd/foo/bar), na "czy cel istnieje" (tylko hdd/data i usb9*) i na migawki.
RWCP="usb9/backups/192.168.28.98/hdd/data"
printf '{"action":"next","roots":["%s"],"excl":{},"recursion":"flat"}\n' "$RWCP" > "$RW/t-cp1.json"
printf '{"action":"next","roots":["hdd/foo/bar"],"excl":{},"recursion":"flat"}\n' > "$RW/t-cp-bar.json"
printf '{"action":"next","roots":["%s","hdd/foo/bar"],"excl":{},"recursion":"flat"}\n' "$RWCP" > "$RW/t-cp-two.json"
rw_copy() {   # <plik drzewa> <argumenty restore.sh...> -- odpowiedzi w $RW/answers; wynik jak rw_run
    local t="$1"; shift
    rm -f "$RW/wt.n" "$RW/wt.log" "$RW/ran" "$RW/last-spec.json"
    ( export NR_DIR="$RW" WHIPTAIL="$RW/bin/whiptail" ZFS_BACKUP="$RW/bin/zb" ZFS_TREE="$RW/bin/tree" \
             ZFS_CONF_DIR="$RW/conf" PYTHON="$PY" PATH="$RW/bin:$PATH" TREE_OUT="$t"
      timeout 60 bash "$REPO/tui/restore.sh" "$@" ) </dev/null >"$RW/out" 2>"$RW/err"
    RW_RC=$?
}

# c1. hdd/data ISTNIEJE -> okno nadpisania ("JUŻ ISTNIEJĄ"); Nadpisz; p0; historia Nie -> --overwrite, bez --at/--with-history
printf '0\tp0\n1\t\n0\thdd/data\n0\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
C1="restore ~ --from-copy=$RWCP ~ --onto=hdd/data ~ --overwrite ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C1" ] && has "$(rw_ran)" '~ --yes' && ! has "$(rw_ran)" '--config' \
   && ! has "$(rw_ran)" '--at' && ! has "$(rw_ran)" '--with-history'; then
    ok "restore --from-copy: cel istnieje, Nadpisz, najnowszy, bez historii -> --from-copy=.. --onto=hdd/data --overwrite --yes (bez --at/--with-history/--config)"
else
    bad "restore --from-copy: nadpisanie" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C1" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi
if grep -qF "\"roots\": [\"$RWCP\"]" "$RW/last-spec.json" 2>/dev/null && grep -qF '"no_exc": true' "$RW/last-spec.json" 2>/dev/null \
   && grep -qF 'JUŻ ISTNIEJĄ' "$RW/wt.log"; then
    ok "restore --from-copy: drzewo dostalo wstepnie zaznaczony korzen (DATASET), a okno nadpisania mowi 'JUŻ ISTNIEJĄ'"
else
    bad "restore --from-copy: spec drzewa / okno nadpisania" "spec: $(cut -c1-300 "$RW/last-spec.json" 2>/dev/null)" "wt: $(grep -c 'ISTNIEJ' "$RW/wt.log")"
fi
# 2026-10-29: podsumowanie z dysku to jedyne "Na pewno?" -- tytul, Wykonaj/Wstecz i zdanie, ze polecenie idzie od razu.
RWCS="$(grep -F -A 30 'Przywróć z dysku: na pewno?' "$RW/wt.log" | head -40)"
if has "$RWCS" '--yes-button ~ Wykonaj ~ --no-button ~ Wstecz' && has "$RWCS" '--defaultno' \
   && has "$RWCS" '<Wykonaj> uruchamia to od razu, bez dalszych pytań; zaszyfrowana kopia -- zapyta tylko o klucz albo plik klucza.'; then
    ok "restore --from-copy: okno 'Przywróć z dysku: na pewno?' ma Wykonaj/Wstecz (--defaultno) i zdanie 'uruchamia to od razu, bez dalszych pytań'"
else
    bad "restore --from-copy: okno 'na pewno?'" "$(printf '%s' "$RWCS" | cut -c1-300)"
fi

# c2. nowa nazwa (nie istnieje -> bez okna nadpisania); starszy punkt p1; historia Tak
printf '0\tp1\n0\t\n0\thdd/restore/data\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
C2="restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data ~ --at=$RWAT ~ --with-history ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C2" ] && ! has "$(rw_ran)" '--overwrite' && ! grep -qF 'ISTNIEJ' "$RW/wt.log"; then
    ok "restore --from-copy: nowy cel, punkt p1, historia Tak -> --onto=hdd/restore/data --at=<czas p1> --with-history, bez --overwrite i bez okna nadpisania"
else
    bad "restore --from-copy: nowy cel + historia" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C2" "err: $(cut -c1-200 "$RW/err")"
fi

# c3. korzen bez wzorca backups -> podpowiedz <pula>/restore/<ostatni czlon>
printf '0\tp0\n1\t\n0\thdd/restore/bar\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp-bar.json" --from-copy
C3="restore ~ --from-copy=hdd/foo/bar ~ --onto=hdd/restore/bar ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C3" ] && grep -qF -- 'hdd/restore/bar ~' "$RW/wt.log"; then
    ok "restore --from-copy: hdd/foo/bar (bez wzorca backups) -> pole 'dokad' podpowiada hdd/restore/bar, --onto=hdd/restore/bar"
else
    bad "restore --from-copy: podpowiedz dla hdd/foo/bar" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C3" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 8 "$RW/wt.log" | cut -c1-300)"
fi
# podpowiedz dla wzorca backups: hdd/data (z usb9/backups/<host>/hdd/data) -- widac w dzienniku c1/c2 jako domyslna wartosc pola
printf '0\tp0\n1\t\n0\thdd/restore/data\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
if grep -qF -- ' ~ hdd/data ~ ' "$RW/wt.log"; then      # argv okna jest wielowierszowy (tekst ma \n) -- domyslna wartosc to ostatni argument
    ok "restore --from-copy: usb9/backups/<host>/hdd/data -> podpowiedz 'hdd/data'"
else
    bad "restore --from-copy: podpowiedz dla wzorca backups" "$(tail -n 6 "$RW/wt.log" | cut -c1-300)"
fi

# c3b (kampania 2026-10-22): kopia z NOSNIKA repliki (<nosnik>/replica/<pula>/...) -> podpowiedz
# <pula>/restore/<czlon>, nie na wyjmowany nosnik; pula spoza hosta (tank) -> jak dotad, na nosnik.
printf '{"action":"next","roots":["usb9/replica/hdd/data/docs"],"excl":{},"recursion":"flat"}\n' > "$RW/t-cp-rep.json"
printf '{"action":"next","roots":["usb9/replica/tank/x"],"excl":{},"recursion":"flat"}\n' > "$RW/t-cp-rep2.json"
printf '0\tp0\n1\t\n0\thdd/restore/docs\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp-rep.json" --from-copy
R3B="$(cat "$RW/wt.log")"   # domyslna wartosc pola stoi w wierszu PO --inputbox (tekst ma \n)
printf '0\tp0\n1\t\n0\thdd/restore/x\n0\t\n' > "$RW/answers"   # usb9/... istnieje w atrapie (okno nadpisania) -- odpowiedz inna niz podpowiedz
rw_copy "$RW/t-cp-rep2.json" --from-copy
R3C="$(cat "$RW/wt.log")"
if [ "$RW_RC" -eq 0 ] && has "$R3B" ' ~ hdd/restore/docs ~' && ! has "$R3B" 'usb9/restore' && has "$R3C" ' ~ usb9/restore/x ~'; then
    ok "restore --from-copy: usb9/replica/hdd/data/docs -> podpowiedz hdd/restore/docs (pula zrodla, nie nosnik); pula spoza hosta -> usb9/restore/x"
else
    bad "restore --from-copy: podpowiedz z nosnika repliki" "rep: $(printf '%s' "$R3B" | cut -c1-300)" "obca: $(printf '%s' "$R3C" | cut -c1-300)"
fi

# c4. dwa korzenie -> dwa pola 'dokad', obie listy w kolejnosci drzewa
printf '0\tp0\n1\t\n0\thdd/restore/data\n0\thdd/restore/bar\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp-two.json" --from-copy
C4="restore ~ --from-copy=$RWCP,hdd/foo/bar ~ --onto=hdd/restore/data,hdd/restore/bar ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C4" ] && [ "$(grep -c -F inputbox "$RW/wt.log")" -eq 2 ]; then
    ok "restore --from-copy: dwa korzenie -> dwa pola 'dokad', --from-copy=A,B --onto=a,b w kolejnosci drzewa"
else
    bad "restore --from-copy: dwa korzenie" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C4" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi

# c6 (P5, wlasciciel 10-15): cel BEZ puli ("restore/home" -- jeden Backspace za duzo) nie
# przechodzi do polecenia: okno "zla nazwa" i to samo pole jeszcze raz; potem poprawna nazwa.
printf '0\tp0\n1\t\n0\trestore/home\n0\t\n0\thdd/restore/data\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data ~ --yes" ] \
   && grep -q 'zła nazwa' "$RW/wt.log" && ! grep -q 'onto=restore/home' "$RW/ran"; then
    ok "restore --from-copy: cel bez puli ('restore/home') -> okno 'zła nazwa' i to samo pole, polecenie dopiero z poprawna nazwa (P5)"
else
    bad "restore --from-copy: cel bez puli (P5)" "rc=$RW_RC ran=$(rw_ran)" "$(grep -c 'zła nazwa' "$RW/wt.log")"
fi
# P1: po biegu napis o Enterze jest NA EKRANIE (stdout), nie schowany w stderr.
# Powodzenie nie czeka na Enter (owner 2026-10-27); od 2026-10-29 napis to wt_end 'Odzysk: gotowe'
# (zamiast '=== GOTOWE (rc=0).'), nadal bez 'Enter = powrót'.
# Stdin tego biegu to /dev/null, wiec o czekaniu swiadczy tekst, nie zawieszenie.
if grep -qx 'Odzysk: gotowe' "$RW/out" && ! grep -q 'GOTOWE (rc=0)' "$RW/out" && ! grep -q 'Enter = powrót' "$RW/out"; then
    ok "restore: po udanym biegu na ekranie 'Odzysk: gotowe' (wt_end) bez prosby o Enter (P1; wyjscie bez czekania)"
else
    bad "restore: napis Enter po biegu (P1)" "$(tail -3 "$RW/out")"
fi

# c5. bez argumentow: uzycie, exit 2
RWU="$( export NR_DIR="$RW" WHIPTAIL="$RW/bin/whiptail" PYTHON="$PY" PATH="$RW/bin:$PATH"; bash "$REPO/tui/restore.sh" </dev/null 2>&1 )"; RWURC=$?
if [ "$RWURC" -eq 2 ] && has "$RWU" 'usage' && has "$RWU" '--from-copy'; then
    ok "restore.sh bez argumentow -> 'usage: ... --from-copy', exit 2"
else
    bad "restore.sh bez argumentow" "rc=$RWURC" "out: $RWU"
fi

# ---- --dataset= / --snapshot= (GUI F4 Kopie, 2026-10-28): okno startuje na wybranej kopii i migawce ----
# a) --from-copy: kopia jest na liscie kandydatow -> pierwsze okno to "dokad" (ani drzewa, ani menu
#    "z kiedy"); migawka starsza (daily) = p1, wiec polecenie ma --at=<czas p1>.
#    Roznica wzgledem starego kodu: stary restore.sh bral $2 = "--dataset=.." za DATASET i pokazywal drzewo.
printf '1\t\n0\thdd/restore/data\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy --dataset="$RWCP" --snapshot=automated_daily_2026-10-14_01-35-01
CA="restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data ~ --at=$RWAT ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$CA" ] && head -n 1 "$RW/wt.log" | grep -qF 'historia' \
   && [ ! -e "$RW/last-spec.json" ] && ! grep -qF 'z kiedy?' "$RW/wt.log" && ! grep -qF 'skąd?' "$RW/wt.log"; then
    ok "restore --from-copy --dataset= --snapshot=: pierwsze okno 'historia' (U109: migawka wybrana, potem dokad), bez drzewa i bez menu 'z kiedy'; polecenie z --from-copy=<kopia> i --at=<czas migawki>"
else
    bad "restore --from-copy --dataset= --snapshot=" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $CA" "err: $(cut -c1-200 "$RW/err")" "wt: $(head -n 2 "$RW/wt.log" | cut -c1-200)"
fi
# b) migawki nie ma: msgbox "nie ma w" i menu jak dotad (p0 = najnowszy -> bez --at)
printf '0\t\n0\tp0\n1\t\n0\thdd/restore/data\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy --dataset="$RWCP" --snapshot=no_such_snap
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data ~ --yes" ] \
   && grep -qF "Migawki no_such_snap nie ma w $RWCP -- wybierz z listy." "$RW/wt.log" && grep -qF 'z kiedy?' "$RW/wt.log"; then
    ok "restore --from-copy --snapshot=<brak>: okno 'Migawki .. nie ma w ..' i menu 'z kiedy' jak dotad"
else
    bad "restore --from-copy --snapshot=<brak>" "rc=$RW_RC" "ran: $(rw_ran)" "err: $(cut -c1-200 "$RW/err")" "wt: $(cut -c1-160 "$RW/wt.log" | head -n 6)"
fi
# c) tryb relacji: kopia z relacji + migawka -> bez drzewa i bez menu przed "dokad"
cp "$RW/plan.remote.json" "$RW/plan.json"      # test 7 zostawil plan bez kopii
printf '0\tobok\n0\thdd/restore\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-whole.json" k2 --dataset=tank/b/hdd/data --snapshot=automated_daily_2026-10-14_01-35-01
CC="restore ~ k2 ~ k2 ~ --source=tank/b/hdd/data,tank/b/hdd/data/docs,tank/b/hdd/data/mail ~ --onto=hdd/restore/data,hdd/restore/data/docs,hdd/restore/data/mail ~ --at=$RWAT ~ --config=$RWCFG ~ --yes"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$CC" ] && [ ! -e "$RW/last-spec.json" ] \
   && grep -qF 'k2: dokąd?' "$RW/wt.log" && ! grep -qF 'z kiedy?' "$RW/wt.log"; then
    ok "restore RELACJA --dataset= --snapshot=: bez drzewa, bez menu 'z kiedy'; pierwsze okno 'dokad', polecenie z --at=<czas migawki>"
else
    bad "restore RELACJA --dataset= --snapshot=" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $CC" "err: $(cut -c1-200 "$RW/err")" "wt: $(cut -c1-160 "$RW/wt.log" | head -n 6)"
fi
# c2) kopia spoza relacji jest ignorowana: drzewo sie pokazuje (atrapa drzewa wraca Wstecz -> rc != 0)
: > "$RW/answers"
rw_copy "$RW/t-back.json" k2 --dataset=tank/zzz/other
if [ "$RW_RC" -ne 0 ] && [ -s "$RW/last-spec.json" ] && [ ! -e "$RW/ran" ]; then
    ok "restore RELACJA --dataset=<spoza relacji>: ignorowane, krok 1 (drzewo) jak dotad"
else
    bad "restore RELACJA --dataset=<spoza relacji>" "rc=$RW_RC" "ran: $(rw_ran)"
fi
# walidacja wartosci: znak spoza listy / '/' w migawce -> blad na stderr, exit 2, zadnego okna
rw_copy "$RW/t-cp1.json" --from-copy --dataset='x;y'
RWV1=$RW_RC; RWE1="$(cat "$RW/err")"
rw_copy "$RW/t-cp1.json" --from-copy --snapshot=a/b
if [ "$RWV1" -eq 2 ] && [ "$RW_RC" -eq 2 ] && has "$RWE1" 'bad --dataset' && has "$(cat "$RW/err")" 'bad --snapshot' && [ ! -s "$RW/wt.log" ]; then
    ok "restore.sh: --dataset= ze znakiem spoza listy i --snapshot= z '/' -> blad na stderr, exit 2, bez okna"
else
    bad "restore.sh: walidacja --dataset=/--snapshot=" "rc1=$RWV1 rc2=$RW_RC" "err1: $RWE1" "err2: $(cat "$RW/err")"
fi
# d) zfs-backup.sh restore NAME --ask --bogus -> "unknown option" (reka dochodzi do tui/restore.sh tylko z --dataset=/--snapshot=)
RWD="$( cd "$RW" && ZFS_BACKUP="$RW/bin/zb" PYTHON="$PY" bash "$REPO/zfs-backup.sh" restore k2 --ask --bogus </dev/null 2>&1 )"; RWDRC=$?
if [ "$RWDRC" -ne 0 ] && has "$RWD" "restore: unknown option '--bogus'"; then
    ok "zfs-backup.sh restore NAME --ask --bogus -> 'restore: unknown option', rc != 0"
else
    bad "zfs-backup.sh restore --ask --bogus" "rc=$RWDRC" "out: $(printf '%s' "$RWD" | cut -c1-300)"
fi
rm -rf "$RW"

# ---- U66/U64 (owner 2026-10-21: "czarny ekran ponad 15 sekund"): run_progress / result_box ----
# The command runs behind an infobox that says how long it has been running and where the log
# is -- no log lines (owner 2026-10-26: they flickered); rc comes back; stdin is /dev/null (a prompt fails instead of hanging).
RP="$(mktemp -d)"; mkdir -p "$RP/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "TERM=$TERM ~ $(printf "%%s ~ " "$@")" >> "%s/wt.log"; for a; do [ "$p" = --textbox ] && cat "$a" >> "%s/wt.log"; p="$a"; done; exit 0\n' "$RP" "$RP" > "$RP/bin/wt"
chmod +x "$RP/bin/wt"
cat > "$RP/cmd" <<'EOF'
#!/bin/bash
echo "krok 1"; sleep 1.3; echo "!!! zrodlo odmowilo: brak miejsca"; read -r x && echo "STDIN: $x"; echo "FATAL: nic nie zmieniono"; exit 3
EOF
chmod +x "$RP/cmd"
( cd "$RP" && WHIPTAIL="$RP/bin/wt" bash -c '. "$1/tui/wt-lib.sh"; : > "$2/run.log"; rc=0
    run_progress "Test" "$2/run.log" "$2/cmd" <<<"tak" || rc=$?; echo "RC=$rc"
    result_box "Wynik" "$rc" "$2/run.log" "" "Nie wyszlo."' x "$REPO" "$RP" ) > "$RP/out" 2>&1
if grep -qx 'RC=3' "$RP/out" && grep -qF 'krok 1' "$RP/run.log" && grep -qF 'FATAL: nic nie zmieniono' "$RP/run.log" \
   && ! grep -qF 'STDIN:' "$RP/run.log" && grep -q -- '^TERM=linux ~ .*--title ~ Test -- trwa [0-9]* s ~ --infobox ~ Trwa wykonywanie' "$RP/wt.log" && ! grep -q '^krok 1 ~ ' "$RP/wt.log" && grep -qF "$RP/run.log" "$RP/wt.log" \
   && grep -qF 'Nie wyszlo.  (rc=3)' "$RP/wt.log" && grep -qF 'zrodlo odmowilo: brak miejsca' "$RP/wt.log" \
   && ! grep -q 'krok 1' "$RP/out"; then
    ok "U66/U64: run_progress -- command behind an infobox (elapsed time, log path, no log lines; TERM=linux so it stays on screen), rc returned, no stdin; result_box shows the reason and the log end"
else
    bad "U66/U64: run_progress/result_box" "$(cat "$RP/out")" "$(cut -c1-200 "$RP/wt.log" | head -8)" "$(cat "$RP/run.log")"
fi
rm -rf "$RP"
# Kampania 2026-10-22: w radioliscie whiptaila Enter bierze ZAZNACZONA kropke, nie podswietlona
# pozycje (strzalka na "Lustro" + Enter = backup; trzeci punkt odzysku + Enter = najnowszy).
# Zadne okno pakietu nie uzywa radiolisty -- wybor jednej pozycji to menu z kursorem na obecnej.
rl_left="$(grep -n -- '--radiolist' "$REPO"/tui/*.sh | grep -v '^\s*#' | head -3)"
[ -z "$rl_left" ] && ok "okna: zadnej radiolisty -- wybor jednej pozycji to menu (Enter = podswietlona)" || bad "okna: radiolista zostala" "$rl_left"
# Kampania 2026-10-22: dlugi plan -- najpierw okno tekstu, potem krotkie pytanie. Przejscie na
# zywo pve10 2026-10-23: okno tekstu BEZ --scrolltext nie przewija (plan uciety na 1. stronie),
# wiec dlugi tekst ma --scrolltext, a w tytule "Tab -> Dalej" (Enter dziala dopiero po Tab,
# zmierzone). Krotki tekst -- jedno okno yesno, jak dotad (textbox_read w wt-lib.sh).
YN="$(mktemp -d)"; mkdir -p "$YN/bin"
printf '#!/bin/bash\nprintf "%%s\\n" "$(printf "%%s ~ " "$@")" >> "%s/wt.log"; exit 0\n' "$YN" > "$YN/bin/wt"; chmod +x "$YN/bin/wt"
seq 1 200 > "$YN/long.txt"; printf 'krotki plan\n' > "$YN/short.txt"
( WHIPTAIL="$YN/bin/wt" bash -c '. "$1/tui/wt-lib.sh"; yesno_text "$2/long.txt" "Plan" "WYKONAJ" "Wstecz" --defaultno; echo "rc=$?"; yesno_text "$2/short.txt" "Plan2" "WYKONAJ" "Wstecz"; echo "rc=$?"' x "$REPO" "$YN" ) > "$YN/out" 2>&1
if [ "$(grep -c 'rc=0' "$YN/out")" -eq 2 ] \
   && grep -q -- '--title ~ Plan  \[strzałki przewijają, Tab -> Dalej, Esc wraca\] ~ --ok-button ~ Dalej ~ --scrolltext ~ --textbox' "$YN/wt.log" \
   && ! grep -- '--title ~ Plan2 ' "$YN/wt.log" | grep -q -- '--scrolltext' \
   && grep -q -- '--title ~ Plan ~ --yes-button ~ WYKONAJ ~ --no-button ~ Wstecz ~ --defaultno ~ --yesno' "$YN/wt.log" \
   && [ "$(grep -c -- '--title ~ Plan2 ' "$YN/wt.log")" -eq 1 ]; then
    ok "yesno_text: dlugi plan = okno tekstu z przewijaniem (Tab -> Dalej w tytule) + krotkie pytanie; krotki = jedno okno"
else
    bad "yesno_text: dlugi plan" "$(cat "$YN/out")" "$(cut -c1-160 "$YN/wt.log")"
fi
rm -rf "$YN"
# ---- U67 (owner 2026-10-21): whole pool in the replica picker; the refusal says WHY ------
U67="$(mktemp -d)"
# verb_refusal: the reason lines above FATAL reach the window (measured on pve10: only the
# FATAL "could not render" line was shown, the gen-cron reason was lost).
printf '%s\n' ">>> plan" "!!! gen-cron.sh (as root) refused the proposed config:" \
    "    gen-cron.sh: error: [replica:usb1]: source='hdd' is a pool name, not a dataset -- name the dataset to copy" \
    "FATAL: gen-cron.sh could not render the proposed config -- nothing was touched" > "$U67/plan.txt"
u67_why="$(bash -c '. "$1/tui/wt-lib.sh" 2>/dev/null; verb_refusal "$2"' x "$REPO" "$U67/plan.txt")"
if printf '%s' "$u67_why" | grep -q "source='hdd' is a pool name" && printf '%s' "$u67_why" | grep -q 'could not render' \
        && ! printf '%s' "$u67_why" | grep -q '^>>>\|^!!!\|^FATAL'; then
    ok "U67: the refusal window gets the reason (gen-cron error line), not only the closing FATAL"
else
    bad "U67: verb_refusal" "$u67_why"
fi
u67_left="$(grep -n "grep -E '^FATAL'" "$REPO"/tui/*.sh | head -3)"
[ -z "$u67_left" ] && ok "U67: no refusal window greps the FATAL line alone any more" || bad "U67: leftover FATAL-only refusal" "$u67_left"
# pool_roots_to_children: the shipped function from tui/replica.sh on a fake tree.
# the function speaks through T/Tv (GUI language): take them from wt-lib.sh the same way
eval "$(sed -n '/^T() {/,/^}/p; /^Tv() {/,/^}/p' "$REPO/tui/wt-lib.sh")"; declare -A TCAT=()
eval "$(sed -n '/^pool_roots_to_children() {/,/^}/p' "$REPO/tui/replica.sh")"
if declare -F pool_roots_to_children >/dev/null; then
    T_NAME=(hdd hdd/a hdd/a/x hdd/b hdd/c hdd/c/y tank tank/z)
    B_ROOT=(hdd tank/z); B_EXCL=($'hdd/b\nhdd/c/y' "")
    pool_roots_to_children; u67_rc=$?
    u67_got="$(printf '%s;' "${SRC_ROOT[@]}")|$(printf '%s;' "${SRC_EXCL[@]}" | tr '\n' ',')"
    # H-1: the basket itself keeps the pool as chosen (Wstecz shows it ticked, not "[-]")
    [ "${B_ROOT[0]}" = hdd ] || u67_got="$u67_got (basket changed: ${B_ROOT[*]})"
    if [ "$u67_rc" -eq 0 ] && [ "$u67_got" = "hdd/a;hdd/c;tank/z;|;hdd/c/y;;" ] && printf '%b' "$POOL_NOTE" | grep -q 'Wybrana cała pula hdd: replika kopiuje 2 datasetów'; then
        ok "U67: a pool root becomes its direct children (excluded child dropped, deeper exclusion follows its child), and the window says so"
    else
        bad "U67: pool root expansion" "rc=$u67_rc got=$u67_got" "$(printf '%b' "$POOL_NOTE")"
    fi
    T_NAME=(empty); B_ROOT=(empty); B_EXCL=("")
    if ! pool_roots_to_children && [ "$POOL_EMPTY" = empty ]; then ok "U67: a pool with no dataset under it is refused with its name"
    else bad "U67: empty pool" "POOL_EMPTY=$POOL_EMPTY roots=${B_ROOT[*]}"; fi
else
    bad "U67: could not lift pool_roots_to_children from tui/replica.sh"
fi
rm -rf "$U67"

# Kampania 3 (2026-10-22, 80x24): pomoc F1 byla przycinana ("kop…", "domyś…") -- teraz
# zawijana. Na prawdziwym HELP z zfs-tui.py: zaden wiersz nie jest szerszy niz okno, nie
# ma wielokropka przyciecia, i nie ginie ani jedno slowo.
if "$PY" - "$REPO/tui/zfs-tui.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^def wrap_hanging.*?(?=^def render_window)", src, re.S | re.M)
h = re.search(r"^HELP = \[(.*?)^\]", src, re.S | re.M)
if not m or not h:
    sys.exit(2)
ns = {}
exec(m.group(0), ns)
lines = eval("[" + h.group(1) + "]")
out = ns["wrap_hanging"](lines, 76)
ok = max(len(l) for l in out) <= 76 and not any(l.endswith(u"\u2026") for l in out)
ok = ok and " ".join(" ".join(lines).split()) == " ".join(" ".join(out).split())
sys.exit(0 if ok else 1)
PYEOF
then
    ok "zfs-tui: pomoc F1 zawijana do 80 kolumn -- zaden wiersz za szeroki, nic nie przyciete, zadne slowo nie zginelo"
else
    bad "zfs-tui: zawijanie pomocy F1" "rc=$?"
fi

# Kampania 3 (2026-10-22, na zywo pve10, 80x24): kazdy recznie lamany wiersz pomocy
# zawijal sie osobno i zostawial sieroty ("czasy", "sortowanie" same w wierszu). Sierota =
# wiersz z jednym slowem we wcieciu opisu, po ktorym idzie dalszy ciag tego samego opisu.
if "$PY" - "$REPO/tui/zfs-tui.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^def wrap_hanging.*?(?=^def render_window)", src, re.S | re.M)
h = re.search(r"^HELP = \[(.*?)^\]", src, re.S | re.M)
ns = {}
exec(m.group(0), ns)
out = ns["wrap_hanging"](eval("[" + h.group(1) + "]"), 76)
ind = lambda l: len(l) - len(l.lstrip(" "))
orph = [l for l, n in zip(out, out[1:]) if ind(l) > 4 and " " not in l.strip() and ind(n) == ind(l)]
sys.exit(1 if orph else 0)
PYEOF
then
    ok "zfs-tui: pomoc F1 przy 80 kolumnach bez sierot -- ogon zawinietego wiersza laczy sie z dalszym ciagiem opisu"
else
    bad "zfs-tui: sieroty w zawijanej pomocy F1" "rc=$?"
fi

# Kampania 3 (2026-10-22, na zywo pve10): listwa klawiszy to dolny wiersz, ktory curses
# konczy kolumne wczesniej -- F4 przy 80 ucinal "Ctrl-R Odświe". Na kazdym ekranie przy 80
# kolumnach tresc listwy (bez dopelnienia spacjami) ma najwyzej 79 znakow.
lw_bad=""
for lw_s in zadania relacje szablony nosniki odzysk; do
    lw_n="$(screen "$lw_s" "" --width 80 | tail -1 | "$PY" -c 'import sys; print(len(sys.stdin.read().rstrip()))')"
    [ "${lw_n:-99}" -le 79 ] || lw_bad="$lw_bad $lw_s=$lw_n"
done
if [ -z "$lw_bad" ]; then
    ok "zfs-tui: listwa klawiszy na kazdym ekranie miesci sie w 79 z 80 kolumn (dolny wiersz bez prawego rogu)"
else
    bad "zfs-tui: listwa klawiszy przy 80 kolumnach" "$lw_bad"
fi

# Kampania 3 (2026-10-22, na zywo pve10): paint tnal kazdy wiersz do w - 1, a uklad ma
# szerokosc ekranu (MIN_WIDTH 80) -- prawa ramka okna nigdy nie trafiala na ekran (od
# wrzesnia). Petli curses nie da sie tu uruchomic: dowodem jest zrzut tmux na pve10; ten
# przypadek pilnuje, ze uklad idzie na w, a pelna szerokosc tnie sie tylko w dolnym wierszu.
if "$PY" - "$REPO/tui/zfs-tui.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"^def curses_loop.*?(?=^def )", src, re.S | re.M)
body = m.group(0) if m else ""
calls = re.findall(r"ui\.render\(([^)]*)\)", body)
ok = calls and all(c.replace(" ", "") == "w,h" for c in calls)
ok = ok and "line = line[:w] if y < h - 1 else line[:w - 1]" in body
sys.exit(0 if ok else 1)
PYEOF
then
    ok "zfs-tui: paint pisze pelna szerokosc (prawa ramka na ekranie), tylko dolny wiersz bez prawego dolnego rogu"
else
    bad "zfs-tui: paint pisze pelna szerokosc ekranu" "rc=$?"
fi

# Kampania 3, wlasciciel 2026-10-23 ("1 popraw to"): po zamknieciu okna linia komunikatu
# mowila "[rc=1] <cala linia polecenia>" takze po zwyklym Esc -- anulowanie wygladalo jak
# blad. Teraz okno zostawia swoje ostatnie slowo (wt_end -> ZFS_TUI_STATUS), a GUI pokazuje
# je, albo "zakonczone" / "zakonczone z kodem N". Prawdziwe UI.window_end_message i wt_end.
WE="$(mktemp -d)"
WE_STUB="$WE/whiptail"; printf '#!/bin/sh
exit 0
' > "$WE_STUB"; chmod +x "$WE_STUB"
ZFS_TUI_STATUS="$WE/s1" WHIPTAIL="$WE_STUB" bash -c ". '$REPO/tui/wt-lib.sh' && wt_end 'Usuń relację: przerwane, nic nie zmieniono'" >/dev/null 2>&1
if "$PY" - "$REPO/tui/zfs-tui.py" "$WE" <<'PYEOF'
import importlib.util, io, os, sys
spec = importlib.util.spec_from_file_location("zt", sys.argv[1]); zt = importlib.util.module_from_spec(spec); spec.loader.exec_module(zt)
we = sys.argv[2]
class U(object): pass
def msg(rc, status, title=u"Usuń relację", log=None):
    u = U(); u.pending_title, u.pending_status_path, u.pending_log_path = title, status, log
    return zt.UI.window_end_message(u, rc)
m1 = msg(1, os.path.join(we, "s1"), log="/root/.zfs-tui/d.log")
m2 = msg(0, os.path.join(we, "brak"))
m3 = msg(2, os.path.join(we, "brak"))
ok = (m1 == u"Usuń relację: przerwane, nic nie zmieniono   dziennik: /root/.zfs-tui/d.log"
      and m2 == u"Usuń relację: zakończone" and m3 == u"Usuń relację: zakończone z kodem 2"
      and not os.path.exists(os.path.join(we, "s1"))
      and not any(u"[rc=" in m for m in (m1, m2, m3))
      and zt.WINDOW_TITLES.get("delete-relation") == u"Usuń relację")
sys.exit(0 if ok else 1)
PYEOF
then
    ok "okno: po zamknieciu linia komunikatu niesie ostatnie slowo okna (wt_end), albo zakonczone/z kodem N -- nigdy [rc=] z linia polecenia"
else
    bad "okno: komunikat po zamknieciu okna" "rc=$?"
fi
# Anulowanie bez zmian (przejscie GUI pve10, 2026-10-28: 3-6 s odswiezenia po Esc w edycji):
# wt_end_nochange pisze ten sam tekst i znacznik "nochange", GUI wraca bez przeladowania;
# zwykle wt_end (okno cos zrobilo) nadal przeladowuje.
ZFS_TUI_STATUS="$WE/n1" WHIPTAIL="$WE_STUB" bash -c ". '$REPO/tui/wt-lib.sh' && wt_end_nochange 'Zmień relację: przerwane, nic nie zmieniono'" >/dev/null 2>&1
ZFS_TUI_STATUS="$WE/n2" WHIPTAIL="$WE_STUB" bash -c ". '$REPO/tui/wt-lib.sh' && wt_end 'Zmień relację: zapisano'" >/dev/null 2>&1
if "$PY" - "$REPO/tui/zfs-tui.py" "$WE" <<'PYEOF'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("zt", sys.argv[1]); zt = importlib.util.module_from_spec(spec); spec.loader.exec_module(zt)
we = sys.argv[2]
class U(object): pass
def end(status):
    u = U(); u.pending_title, u.pending_status_path, u.pending_log_path = u"Zmień relację", status, None
    return zt.UI.window_end_message(u, 1), getattr(u, "noreload_after", False)
m1, n1 = end(os.path.join(we, "n1"))
m2, n2 = end(os.path.join(we, "n2"))
sys.exit(0 if (m1 == u"Zmień relację: przerwane, nic nie zmieniono" and n1 is True
               and m2 == u"Zmień relację: zapisano" and n2 is False) else 1)
PYEOF
then
    ok "okno: zamkniete bez zmian (wt_end_nochange) -> GUI bez pelnego odswiezenia; zwykle wt_end odswieza"
else
    bad "okno: nochange po anulowaniu" "rc=$?"
fi

# Kampania 3 (2026-10-23, na zywo pve10): panel "ab -- pobranie" mowil "Trzyma -", choc zadanie
# niesie retain -H24 -- wiersz transferu ma w kolumnie "-" (retencja stoi w wierszu porzadkow),
# a panel bral to "-". Prawdziwe job_panel_pairs na wierszu o ksztalcie z pve10.
if "$PY" - "$REPO/tui/zfs-tui.py" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("zt", sys.argv[1]); zt = importlib.util.module_from_spec(spec); spec.loader.exec_module(zt)
def trzyma(j, keep):
    row = {"job": j, "keep": keep, "dir": "pull", "task": u"pobranie", "schedule": "15 * * * *"}
    try:
        class E(dict):           # pusty slownik, a wolany jak metoda -- falsz (data.failed(...))
            def __call__(self, *a, **k): return False
        class D(object):
            def __getattr__(self, n): return E()
        pairs = zt.job_panel_pairs(row, D(), 1788960000, None)
    except Exception as e:
        return "EXC %s" % e
    return dict((k, v) for k, v in pairs if k).get(u"Trzyma")
j = {"direction": "pull", "scope": "hdd/backups/x/hdd/data", "src": "z@h:hdd/data", "retain": "-H24", "schedule": "15 * * * *"}
a = trzyma(j, "-")
b = trzyma(dict(j, retain=""), "-")
sys.exit(0 if (a == u"24 godz." and b == u"-") else 1)
PYEOF
then
    ok "panel zadania: transfer z retain -H24 mowi 'Trzyma 24 godz.', bez retain -- '-'"
else
    bad "panel zadania: Trzyma dla wiersza transferu" "rc=$?"
fi

# Kampania 3 (2026-10-23, punkt 3): kreator kopii/migawek lokalnych proponowal nosniki replik
# (gwlive, replab) jako zrodla. drop_replica_media jest teraz w basket-lib.sh i kreator lokalny
# go wola: nosnik wymienny znika cala pula, staly -- swoim katalogiem z poddrzewem.
DRM="$(mktemp -d)"
printf '%s' '{"datasets":[{"name":"gwlive"},{"name":"gwlive/data"},{"name":"hdd"},{"name":"hdd/data"},{"name":"hdd/repl"},{"name":"hdd/repl/x"},{"name":"hdd/replika"},{"name":"replab"},{"name":"replab/replica"},{"name":"replab/replica/hdd"}]}' > "$DRM/ds.json"
printf '%s' '{"replicas":[{"name":"usb","dst":"gwlive/replica","media":"removable"},{"name":"st","dst":"hdd/repl","media":"fixed"},{"name":"cp","dst":"replab/replica","media":"fixed"}]}' > "$DRM/rep.json"
DRM_STUB="$DRM/whiptail"; printf '#!/bin/sh
exit 0
' > "$DRM_STUB"; chmod +x "$DRM_STUB"
drm_left="$(WHIPTAIL="$DRM_STUB" bash -c ". '$REPO/tui/wt-lib.sh' && . '$REPO/tui/basket-lib.sh' && drop_replica_media '$DRM/ds.json' '$DRM/rep.json'" 2>&1; "$PY" -c 'import json,sys; print(" ".join(x["name"] for x in json.load(open(sys.argv[1]))["datasets"]))' "$DRM/ds.json")"
if [ "$drm_left" = "hdd hdd/data hdd/replika" ] && grep -q 'drop_replica_media "$TMPD/ds.json" "$TMPD/rep.json"' "$REPO/tui/new-relation.sh"; then
    ok "kreator lokalny: nosniki replik nie sa zrodlem -- wymienny cala pula, staly katalogiem (hdd/replika zostaje), pula stalego nosnika bez niczego wiecej tez znika (replab)"
else
    bad "kreator lokalny: nosniki replik na liscie zrodel" "zostalo: $drm_left"
fi

# U31: okno planu kopii lokalnej pokazuje sekcje i linie crona TEJ relacji, nie caly config i
# caly crontab hosta (pve10 2026-10-23: 331 linii z relacjami ab i cb). Funkcja z produkcji.
POT="$(mktemp -d)"
sed -n '/^plan_only_this()/,/^}/p' "$REPO/tui/new-relation.sh" > "$POT/f.sh"
cat > "$POT/plan.txt" <<'EOF'
>>> local-backup: uwaga
--- candidate CONFIG v4 (full: existing + new job) ---
[defaults]
	quiesce = no
[relation:ab]
	tiers = hourly
[dataset:hdd/backups/x]
	relation     = ab
[relation:t5]
	tiers = hourly
[dataset:hdd/archive]
	relation     = t5
	pair_label   = t5
[prune:hdd/restore/t5/hdd/archive]
	pair_label   = t5

--- generated cron block (gen-cron.sh -c, full) ---
15 * * * * zfs-job.sh "pve10 profile__relacja-ab__hourly snapshot (ab-x)"
29 * * * * zfs-job.sh "pve10 profile__relacja-t5__lsrc_hourly snapshot (local-archive)"
*/15 * * * * d=$(check-snap-age.sh -R -L t5 "hdd/archive")
*/15 * * * * d=$(check-snap-age.sh -R -L ab "hdd/backups/x")

To jest wylacznie plan -- nic nie zostalo zainstalowane.
EOF
pot_out="$(bash -c ". '$POT/f.sh'; plan_only_this t5" < "$POT/plan.txt")"
if printf '%s\n' "$pot_out" | grep -qxF '[relation:t5]' && printf '%s\n' "$pot_out" | grep -qxF '[dataset:hdd/archive]' \
   && printf '%s\n' "$pot_out" | grep -qxF '[prune:hdd/restore/t5/hdd/archive]' \
   && printf '%s\n' "$pot_out" | grep -qF 'relacja-t5__lsrc_hourly' && printf '%s\n' "$pot_out" | grep -qF -- '-L t5 ' \
   && ! printf '%s\n' "$pot_out" | grep -qE 'relacja-ab|\[relation:ab\]|\[defaults\]|-L ab ' \
   && printf '%s\n' "$pot_out" | grep -qF 'sekcje configu: 3, linie crona: 2' \
   && printf '%s\n' "$pot_out" | grep -qF 'To jest wylacznie plan' && printf '%s\n' "$pot_out" | grep -qF '>>> local-backup: uwaga' \
   && grep -qF 'plan_only_this "$RNAME"' "$REPO/tui/new-relation.sh"; then
    ok "kreator: plan kopii lokalnej -- tylko sekcje i crona tej relacji, reszta policzona (U31)"
else
    bad "kreator: plan kopii lokalnej filtrowany do tej relacji (U31)" "$pot_out"
fi
rm -rf "$POT"

# REV-20261023-172: klawisz po oknie, gdy odświeżanie w tle trwa dłużej niż limit, nie może nic
# zaplanować na STARYCH wierszach (Del, F7, strzałka); po wejściu świeżych danych ten sam Del
# celuje w świeży wiersz -- także gdy wątek skończył, a pętla jeszcze nie odebrała danych.
# Prawdziwe UI.key()/poll_bg z produkcji, podmieniony tylko collect (bez poleceń i hostów).
sbg_out="$("$PY" "$REPO/test/tui/stale_bg_gate.py" "$TUI" 2>&1 | tr -d '\r')"
sbg_bad="$(printf '%s\n' "$sbg_out" | grep -c '^bad ')"
sbg_ok="$(printf '%s\n' "$sbg_out" | grep -c '^ok ')"
if [ "$sbg_ok" -eq 13 ] && [ "$sbg_bad" -eq 0 ]; then
    ok "odświeżanie w tle po limicie: Del/F7/strzałka nic nie planują na starych wierszach, nieudane odświeżenie przepuszcza tylko klawisze niezależne od wierszy (Ins na Szablonach też stoi), po świeżych danych Del i Ins celują w świeże (REV-172, REV-173)"
else
    bad "odświeżanie w tle: klawisz na starych wierszach (REV-172)" "$sbg_out"
fi

# Limit czytnika GUI: zawieszony czytnik (ssh do martwego hosta) wraca błędem w limicie i nie
# zostawia procesów; zwykły czytnik dalej daje JSON. Prawdziwe run_verb() z produkcji.
rto_out="$("$PY" "$REPO/test/tui/reader_timeout.py" "$TUI" 2>&1 | tr -d '\r')"
if [ "$(printf '%s\n' "$rto_out" | grep -c '^ok ')" -eq 3 ] && ! printf '%s\n' "$rto_out" | grep -q '^bad '; then
    ok "czytnik GUI: limit czasu -- zawieszony wraca błędem i ginie z dziećmi, zwykły daje JSON"
else
    bad "czytnik GUI: limit czasu" "$rto_out"
fi

# JĘZYK OKIEN (P0 tłumaczenia, 2026-10-24): katalog tui/lang/en.json ma wpis dla każdego tekstu
# podanego do T/_(). Właściciel 2026-10-24: domyślnie ANGIELSKI (publikacja dla społeczności
# Proxmoxa); polski z --lang=pl / ZFS_TUI_LANG=pl / [gui] language = pl. Testy wyżej przypinają
# polski przez ZFS_TUI_LANG=pl.
lc_out="$("$PY" "$REPO/test/tui/lang_catalog.py" "$REPO" 2>&1 | tr -d '\r')"
LGS="$(mktemp -d)"; printf '[gui]\nlanguage = pl\n' > "$LGS/settings.ini"
bar_pl="$(env -u ZFS_TUI_LANG SETTINGS_FILE=/nonexistent "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --screen relacje --width 100 --lang pl 2>&1 | tail -1)"
bar_en="$(env -u ZFS_TUI_LANG SETTINGS_FILE=/nonexistent "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --screen relacje --width 100 2>&1 | tail -1)"
bar_set="$(env -u ZFS_TUI_LANG SETTINGS_FILE="$LGS/settings.ini" "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --screen relacje --width 100 2>&1 | tail -1)"
t_pl="$(ZFS_TUI_LANG=pl WHIPTAIL=true bash -c '. "$1/tui/wt-lib.sh"; T Dalej; T "Nowa relacja -- krok %s z %s: %s" 1 6 X' x "$REPO")"
t_en="$(env -u ZFS_TUI_LANG SETTINGS_FILE=/nonexistent WHIPTAIL=true bash -c '. "$1/tui/wt-lib.sh"; T Dalej; T "Nowa relacja -- krok %s z %s: %s" 1 6 X; T "tekst bez wpisu"' x "$REPO")"
t_set="$(env -u ZFS_TUI_LANG SETTINGS_FILE="$LGS/settings.ini" WHIPTAIL=true bash -c '. "$1/tui/wt-lib.sh"; T Wstecz' x "$REPO")"
rm -rf "$LGS"
if [ "$(printf '%s\n' "$lc_out" | grep -c '^ok ')" -eq 2 ] \
   && has "$bar_pl" '3Relacje' && has "$bar_pl" '12Wyjście' \
   && has "$bar_en" '3Relations' && has "$bar_en" '12Quit' && ! has "$bar_en" 'Relacje' \
   && has "$bar_set" '3Relacje' \
   && [ "$t_pl" = "DalejNowa relacja -- krok 1 z 6: X" ] \
   && [ "$t_en" = "NextNew relation -- step 1 of 6: Xtekst bez wpisu" ] && [ "$t_set" = "Wstecz" ]; then
    ok "język okien: katalog pełny dla T/_(), domyślnie po angielsku, polski z --lang/ZFS_TUI_LANG/settings"
else
    bad "język okien (P0)" "$lc_out" "pl=[$bar_pl]" "en=[$bar_en]" "set=[$bar_set]" "t_pl=[$t_pl] t_en=[$t_en] t_set=[$t_set]"
fi

# NAZWY BEZ DEFINICJI (wlasciciel 2026-10-28, pve10: F2 na dole listy -> NameError
# 'transfer_detail_pairs'). #928 usunal funkcje razem z F4 Historia, a Przebiegi wolaly ja
# dalej -- tylko dla biegu z zapisem transferu, czego zaden test nie renderowal. Python
# zglasza taka nazwe dopiero w chwili wywolania; ten test czyta kazdy plik tui/*.py (AST) i
# odrzuca kazde odwolanie do nazwy, ktora nigdzie w pliku nie jest zdefiniowana,
# zaimportowana ani wbudowana (__file__ to globalna modulu).
undef="$("$PY" - "$REPO"/tui/*.py <<'PYU'
import ast, builtins, sys
for path in sys.argv[1:]:
    tree = ast.parse(open(path, encoding='utf-8').read())
    known = set(dir(builtins)) | {'__file__'}
    for n in ast.walk(tree):
        if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            known.add(n.name)
        elif isinstance(n, (ast.Import, ast.ImportFrom)):
            known.update((a.asname or a.name).split('.')[0] for a in n.names)
        elif isinstance(n, ast.Name) and not isinstance(n.ctx, ast.Load):
            known.add(n.id)
        elif isinstance(n, ast.arg):
            known.add(n.arg)
        elif isinstance(n, ast.ExceptHandler) and n.name:
            known.add(n.name)
        elif isinstance(n, ast.Global):
            known.update(n.names)
    for n in ast.walk(tree):
        if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load) and n.id not in known:
            print('%s:%d %s' % (path.rsplit('/', 1)[-1], n.lineno, n.id))
PYU
)"
if [ -z "$undef" ]; then
    ok "tui/*.py: kazda wolana nazwa jest gdzies zdefiniowana (AST) -- brak NameError czekajacego na rzadka galaz"
else
    bad "tui/*.py: nazwy bez definicji" "$undef"
fi

# F4 KOPIE, KOPIA LOKALNA (pve2 po wydaniu 2026-10-28): para relacji lokalnej podaje jako cel
# BAZE (hdd/backups/pve2), a kopia lezy pod baza/zrodlo -- grupa pokazywala cale drzewo bazy,
# z kopiami innych relacji. kopie_copy_root: pull bez zmian, lokalna = baza/zrodlo.
kcr="$("$PY" -c '
import importlib.util, sys
sp = importlib.util.spec_from_file_location("zt", sys.argv[1]); m = importlib.util.module_from_spec(sp); sp.loader.exec_module(m)
print(m.kopie_copy_root("hdd/backups/pve2", "rpool/data/vm-106-disk-0"))
print(m.kopie_copy_root("hdd/backups/192.168.28.99/hdd/lab/vm-101", "zbk@192.168.28.99:hdd/lab/vm-101"))
print(m.kopie_copy_root("hdd/backups/pve2/", "hdd/vm-disks/subvol-107-disk-0 (+2)"))
' "$TUI" 2>&1)"
if [ "$kcr" = "hdd/backups/pve2/rpool/data/vm-106-disk-0
hdd/backups/192.168.28.99/hdd/lab/vm-101
hdd/backups/pve2/hdd/vm-disks/subvol-107-disk-0" ]; then
    ok "kopie: kopia lokalna = baza/zrodlo (nie cala baza), pull bez zmian"
else
    bad "kopie: sciezka kopii z pary relacji" "$kcr"
fi

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
