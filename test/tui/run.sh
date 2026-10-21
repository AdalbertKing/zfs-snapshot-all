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

NOW=1788960000   # 2026-09-09, srodek dnia -- deterministyczny "nastepny bieg"
ALL="--status $P10/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor.json --progress $P10/progress.json --replicas $P10/replicas.json --config $P10/show-config.json --stats $P10/job-stats.json"
PAUSED="--status $P10/status-paused.json --jobs $P10/list-jobs.json --monitors $P10/monitor-paused.json --progress $P10/progress.json --replicas $P10/replicas.json"

screen() {   # <screen> [keys] [extra args...] -> ekran jako tekst, fikstury pve10
    local sc="$1" keys="${2:-}"; shift; [ $# -gt 0 ] && shift
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen "$sc" --keys "$keys" "$@" 2>&1
}
has()  { printf '%s' "$1" | grep -qF -- "$2"; }
hasE() { printf '%s' "$1" | grep -qE -- "$2"; }

# ============================================================================
# EKRAN 1: RELACJE -- wiersz to RELACJA (para hostow), nie zadanie
# ============================================================================
S="$(screen relacje)"
S120="$(screen relacje "" --width 120)"
S200="$(screen relacje "" --width 200)"
# F3 W TRZECH PANELACH (szkic wlasciciela, 2026-09-11): lista jest WASKA, wiec
# kolumny Kopie i Nastepny dochodza z szerokoscia; przy 80 sa trzy.
if hasE "$S200" '^║ lab-ct201 +backup +pve10<192.168.28.99 +działa +aktualne +║│'; then
    ok "relacje: jeden wiersz na RELACJE -- nazwa, typ, KIERUNEK (ten host po lewej), stan z rekordu, kopie z monitora (U21: GB i nastepny bieg w panelu)"
else
    bad "relacje: wiersz relacji sklejony z czterech czytelnikow" "$S200"
fi
if hasE "$S" '^║ lab-ct201 +działa +aktualne +║│' && hasE "$S" '^║ Relacja +Stan +Kopie +║│' && hasE "$S120" '^║ lab-ct201 +backup +pve10<192.168.28.99 +działa +aktualne +║│'; then
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
if hasE "$S200" '^║ duplikat +backup +pve10[?]192.168.28.99 +1\. kopia +-- +║' && hasE "$S120" 'Następny +seed duplikat'; then
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
if has "$S" 'duplikat (wg rekordu, nie crona): [Datasety]  Zadania' && has "$S120" '192.168.28.99:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
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
ZT="$(screen zadania down --width 100 --height 40)"
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
S4R="$(printf '%s\n' "$S4" | grep -E '^║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101 +aktualne +[0-9]+ +[0-9.]+[KMG]' | head -1)"
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
EB="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen transfery --keys "" --progress "$BAD" --width 100 2>&1)"
if has "$EB" 'zfs-backup.sh progress --json' && has "$EB" 'błąd źródła' && ! has "$EB" 'Uruchom czasownik ręcznie'; then
    ok "zepsute zrodlo: ekran nazywa DOKLADNA komende do wpisania, zamiast odsylac do 'czasownika'"
else
    bad "zepsute zrodlo: brak komendy" "$EB"
fi

# POMOC MA OPISYWAC TO, CO JEST. Po usunieciu kreatora curses (2026-09-21)
# ekran F1 nadal opisywal jego siedem krokow i klawisze, ktorych juz nie ma --
# tekst pomocy to tez ekran, i tez sie dezaktualizuje.
H1="$(screen zadania F1 --width 100 --height 120)"
if ! has "$H1" 'kreator w 7 krokach' && ! has "$H1" 'Enter na źródle/celu' && has "$H1" 'kreator w 10 krokach' && has "$H1" 'whiptail'; then
    ok "pomoc: opisuje kreator, ktory NAPRAWDE sie otwiera (10 okien whiptaila), a nie usunietego poprzednika"
else
    bad "pomoc: nieaktualny opis kreatora" "$(printf '%s' "$H1" | sed -n '4,14p')"
fi
# R4-2: pomoc mowi, ze F7-F9 to akcje okna, Ctrl-R odswieza, a litery NIGDY nie sa skrotami.
# F5 od 2026-10-09 to ekran Szablony (uwaga 24), odswiezanie zostaje pod Ctrl-R.
if has "$H1" "F7 chowa/pokazuje transfery" && has "$H1" "F7 F8 F9          akcje BIEŻĄCEGO okna" \
   && has "$H1" "Ctrl-R            odśwież" && ! has "$H1" "F5 / Ctrl-R" && ! has "$H1" "wyjątek: 'u'" && ! has "$H1" "F9 / Ctrl-R"; then
    ok "pomoc: F7-F9 = akcje okna, Ctrl-R odswieza, bez wyjatku dla liter (R4-2)"
else
    bad "pomoc: klawisze R4-2" "$H1"
fi

# SZEROKOSC: KOLUMNY PO PRIORYTECIE (R3-4; R4-4 dolozyl Prefiks/Trzyma/szt.).
# Kierunek NIE UCINA SIE NIGDY (pelny adres synchro). Kolejnosc wchodzenia:
# Relacja, Kierunek, Zadanie, Kopie, Nastepny, Prefiks, Trzyma, szt.,
# Harmonogram, GB, Czas -- przy 100 kolumnach Harmonogram jest juz tylko w
# panelu (11 kolumn sie nie miesci). Panel idzie OBOK
# listy od 150, nie od 120 jak wczesniej (punkt 3) -- 120 zabieral liscie
# miejsce, ktorego panelowi i tak nie oddawal w calosci.
Z100="$(screen zadania "" --width 100)"
if has "$Z100" 'Zadanie' && has "$Z100" 'Następny' && has "$Z100" 'Kopie' && ! printf '%s\n' "$Z100" | sed -n '3,6p' | grep -q '…'; then
    ok "zadania: przy 100 kolumnach lista ma Relacje, Zadanie, Nastepny i Kopie, nic nie uciete (U21: Prefiks spada pierwszy)"
else
    bad "zadania: kolumny przy 100" "$(printf '%s' "$Z100" | sed -n '3,5p')"
fi
# 260: od 150 panel stoi obok i lista ma 60% szerokosci; 11 kolumn R4-4
Z160="$(screen zadania "" --width 260)"
if has "$Z160" 'Relacja' && has "$Z160" 'Zadanie' && has "$Z160" 'Prefiks migawek' && has "$Z160" 'Następny' && has "$Z160" 'Kopie' \
   && ! has "$Z160" 'Harmonogram' && ! has "$Z160" 'Czas o/ś/m' && ! has "$Z160" 'szt.'; then
    ok "zadania: przy 260 kolumnach piec naglowkow listy (U21: kierunek, harmonogram, retencja, czasy -- w panelu)"
else
    bad "zadania: naglowki przy 160" "$(printf '%s' "$Z160" | sed -n '3p')"
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
        *"Czas..."*|*"Kopie …"*|*"Kopie..."*|*"Harmonogr…"*|*"Następn…"*) bad "zadania: uciety NAGLOWEK kolumny przy $_w" "$_h" ;;
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
_ct=$(printf '%s' "$S4CT" | grep -cE '^║ zfsbackup-pve10@192.168.28.99:hdd/lab/ct-201 → ')
if [ "$_ct" -le 1 ] && ! has "$S4CT" 'ct-201: 4 pary'; then
    ok "relacje: dataset z kilkoma szczeblami zajmuje JEDEN wiersz panelu, nie tyle wierszy, ile ma linii crona"
else
    bad "relacje: powtorzony dataset w panelu par" "wierszy ct-201: $_ct" "$(printf '%s' "$S4CT" | grep -E 'Datasety relacji' | head -1)"
fi

S4_120="$(screen relacje down,down,down,down --width 120)"
if hasE "$S4_120" '^║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 → .* +aktualne +1 +[0-9.]+[KMG] +║'; then
    ok "relacje: przy 120 dataset w jednym wierszu z liczbami; pelne sciezki w panelu po Tab"
else
    bad "relacje: pary przy 120" "$S4_120"
fi
S4_80="$(screen relacje down,down,down,down)"
if hasE "$S4_80" '^║ zfsbackup-pve10@192.168.28.99:hdd/.* +aktualne +1 +[0-9.]+[KMG] +║'; then
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
if has "$TP" 'm migawki   Enter pełne okno   ←→ zakładki   Esc wróć   Tab do linii poleceń' && has "$TP" 'lab-ct201 -- dataset'; then
    ok "relacje: Tab przenosi kursor na datasety, prawy panel pokazuje zaznaczony dataset (U21); na ramce m migawki (U38)"
else
    bad "relacje: Tab" "$TP"
fi
TE="$(screen relacje down,tab,enter --height 60)"
if ! has "$TE" 'Zadania na pve10' && has "$TE" '╔═ Zadanie: lab-ct201  pobranie  automated_hourly' \
   && hasE "$TE" 'Źródło +zfsbackup-pve10@192\.168\.28\.99:hdd/lab/ct-201' && has "$TE" '── CONFIG ' && has "$TE" '── CRON ' \
   && has "$TE" 'snapget.sh -m'; then
    ok "relacje: Enter na datasecie = okno jego zadania (szczegoly, CONFIG, CRON) na F3, bez skoku na F2 (R4-6)"
else
    bad "relacje: Enter na parze" "$TE"
fi
TEE="$(screen relacje down,tab,down,enter,esc)"
if has "$TEE" 'Relacje na kolektorze' && has "$TEE" 'Enter pełne okno   ←→ zakładki' && ! has "$TEE" '╔═ Zadanie:'; then
    ok "relacje: Esc z okna datasetu wraca na dolny panel (kursor zostaje na datasetach)"
else
    bad "relacje: Esc z okna pary" "$TEE"
fi
TR="$(screen relacje tab,enter)"
if has "$TR" 'Relacje na kolektorze' && has "$TR" 'ten dataset jest z rekordu, nie z crona'; then
    ok "relacje: Enter na datasecie z REKORDU mowi, ze nie ma jego linii ani sekcji"
else
    bad "relacje: Enter na parze z rekordu" "$TR"
fi

# --- PAUZA: prawdziwy stan z pause-client na pve10 -------------------------
SP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down --width 200 2>&1)"
if hasE "$SP" '^║ lab-srv-b +backup +pve10<192.168.28.99 +działa PAUZA +aktualne +║' && hasE "$SP" 'Następny +-- pauza --'; then
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
if has "$Z" '╔═ Zadania na pve10 (32 zadania, 4 relacje) -- sort'; then
    ok "zadania: F2 liczy zadania z crona i relacje, ktore je maja, tytul nazywa domyslny widok sortowania"
else
    bad "zadania: tytul" "$Z"
fi
# R3-4: kolejnosc kolumn po priorytecie zmienila sie (Kopie/GB/Czas nie sa juz w
# tej samej kolejnosci co dawniej, Harmonogram i Nastepny moga wejsc miedzy
# Zadanie a nimi) -- sprawdzamy PREFIKS wiersza (Relacja/Kierunek/Zadanie, ktore
# sa priorytetem 1-3 i zawsze pierwsze) i ze werdykt gdzies na tym wierszu jest,
# bez wiazania sie do dokladnej pozycji kolumn koncowych.
if hasE "$Z" '^║ lab-vm101 +pobranie +automated_hourly ' && hasE "$Z" 'Kierunek +pve10<192\.168\.28\.99' && ! has "$Z" 'Zakres'; then
    ok "zadania: POBRANIE nazywa sie pobraniem (nie 'wysylka'), kierunek 'pve10<peer' w panelu (U21), bez 'Zakres' dla jednego datasetu"
else
    bad "zadania: wiersz wysylki" "$Z"
fi
ZL="$(screen zadania down --width 120)"
if hasE "$Z" '^║ lab-vm101 +lokalny prune +automated_hourly ' && hasE "$ZL" 'Kierunek +lokalnie, na tym hoście' && hasE "$ZL" 'Trzyma +24 godz\.'; then
    ok "zadania: porzadki na ladowisku = 'lokalny prune', rodzina w Prefiksie; w panelu 'lokalnie, na tym hoście' i retencja z jednostka"
else
    bad "zadania: wiersz porzadkow" "$Z" "$ZL"
fi
ZR="$(screen zadania down,down,down,down,down --width 120)"
if [ "$(printf '%s\n' "$Z" | grep -cE '^║ lab-vm101 +zdalny prune +automated_hourly ')" -ge 1 ] && has "$ZR" 'lab-vm101 -- zdalny prune' && hasE "$ZR" 'Kierunek +pve10<192\.168\.28\.99'; then
    ok "zadania: porzadki na ZDALNYM zrodle niosa kierunek relacji, nie 'lokalnie'"
else
    bad "zadania: zdalne porzadki" "$Z" "$ZR"
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
Z200="$(screen zadania "" --width 260)"
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
ZS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --stats "$FIX/nie-ma.json" --screen zadania --width 200 2>&1)"
# R3-4: Kopie/GB/Czas zamienily miejsca w priorytecie (Kopie teraz przed GB i
# Czas) -- sprawdzamy fakty NA WIERSZU bez wiazania sie do ich wzajemnej
# kolejnosci.
ZS_LINE=$(printf '%s\n' "$ZS" | grep -E '^║ lab-vm101 +pve10<192\.168\.28\.99 ')
QCOUNT=$(printf '%s' "$ZS_LINE" | grep -o '?' | wc -l | tr -d ' ')
ZS_LINE=$(printf '%s\n' "$ZS" | grep -E '^║ lab-vm101 +pobranie ')
if [ -n "$ZS_LINE" ] && printf '%s' "$ZS_LINE" | grep -qF 'aktualne' \
   && has "$ZS" '? -- job-stats nie odpowiedział' && has "$ZS" '! bez odpowiedzi: 1'; then
    ok "zadania: zepsute job-stats -> '?' i zdanie w panelu, nigdy zero udajace pomiar"
else
    bad "zadania: zepsute job-stats" "$ZS_LINE" "$ZS"
fi
ZH3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --stats "$P10/job-stats.json" --screen zadania --width 200 2>&1)"
ZH3_LINE=$(printf '%s\n' "$ZH3" | grep -E '^║ pve9 +hostA>pve9 +wysyłka +automated_hourly ')
ZH3_LINE=$(printf '%s\n' "$ZH3" | grep -E '^║ pve9 +wysyłka +automated_hourly ')
if [ -n "$ZH3_LINE" ] && printf '%s' "$ZH3_LINE" | grep -qF 'spóźnione' \
   && has "$ZH3" 'brak biegów w dzienniku z tego okna'; then
    ok "zadania: zadanie, ktorego nie ma w dzienniku, pokazuje werdykt i mowi 'brak biegow' w panelu"
else
    bad "zadania: brak biegow" "$ZH3_LINE" "$ZH3"
fi

# SORTOWANIE F2 (test c, R3-4; R4-2: F8, nie 's'): F8 (X9: bylo F7) cykluje trzy widoki, tytul mowi ktory.
# jobs.json (fixture hostA) ma zadanie GODZINOWE "wysyłka hourly" (schedule
# "5 * * * *" -- nastepny bieg w ciagu godziny od NOW) i zadanie DOBOWE
# "kopia daily" (schedule "21 0 * * *" -- NOW jest "środek dnia", 00:21 juz
# minelo, nastepny bieg dopiero jutro) -- kolejnosc miedzy nimi w widoku "os
# czasu" jest wiec DETERMINISTYCZNA niezaleznie od dokladnej minuty NOW.
ZJARGS="--jobs $FIX/jobs.json --monitors $FIX/monitors.json"
ZSORT1="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8 --width 200 2>&1)"
if has "$ZSORT1" 'sort: oś czasu'; then
    ok "zadania: F8 raz -- tytul mowi 'oś czasu'"
else
    bad "zadania: F8 raz -- tytul" "$ZSORT1"
fi
L1=$(printf '%s\n' "$ZSORT1" | grep -n 'wysyłka ' | head -1 | cut -d: -f1)
L2=$(printf '%s\n' "$ZSORT1" | grep -n 'kopia ' | head -1 | cut -d: -f1)
L1=$(printf '%s\n' "$ZSORT1" | grep -n '^║ .*wysyłka ' | head -1 | cut -d: -f1)
L2=$(printf '%s\n' "$ZSORT1" | grep -n '^║ .*kopia ' | head -1 | cut -d: -f1)
if [ -n "$L1" ] && [ -n "$L2" ] && [ "$L1" -lt "$L2" ]; then
    ok "zadania: F8 raz (oś czasu) -- 'wysyłka hourly' (biegnie w ciagu godziny) przed 'kopia daily' (biegnie dopiero jutro)"
else
    bad "zadania: F8 raz -- kolejnosc wierszy" "L1=$L1 L2=$L2" "$ZSORT1"
fi
ZSORT2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8,F8 --width 200 2>&1)"
if has "$ZSORT2" 'sort: ostatni bieg'; then
    ok "zadania: F8 dwa razy -- tytul mowi 'sort: ostatni bieg'"
else
    bad "zadania: F8 dwa razy -- tytul" "$ZSORT2"
fi
ZSORTS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys s --width 200 2>&1)"
if has "$ZSORTS" 'sort: relacje' && has "$ZSORTS" '$ s_ '; then
    ok "zadania: 's' to TEKST linii polecen -- widok sortowania zostaje (R4-2)"
else
    bad "zadania: 's' jako tekst" "$ZSORTS"
fi
ZSORT3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ZJARGS --screen zadania --keys F8,F8,F8 --width 200 2>&1)"
if has "$ZSORT3" 'sort: relacje' && ! has "$ZSORT3" 'oś czasu' && ! has "$ZSORT3" 'ostatni bieg'; then
    ok "zadania: F8 trzy razy -- wraca do domyslnego widoku (relacje, w srodku wg nastepnego)"
else
    bad "zadania: F8 trzy razy -- powrot" "$ZSORT3"
fi

# ============================================================================
# R4-3/R4-5: co najmniej dwie spacje miedzy kolumnami; kiedy wszystkie sie
# mieszcza, zapas idzie w odstepy, a nie w pustke po prawej (zrzut wlasciciela
# z pve11 przy ~190 kolumnach). Fikstura hostA: 11 kolumn, przy 200 lista ma 130.
R45N="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 100 2>&1 | sed -n 3p)"
R45W="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 260 2>&1 | sed -n 3p)"
_r45="${R45N%%║│*}"
if printf '%s' "$R45N" | grep -qE 'Relacja  +Zadanie' && ! printf '%s' "${_r45#║ }" | grep -qE '[^ ] [A-ZŁŚ][a-zęąśłó]' \
   && printf '%s' "$R45W" | grep -qE 'Relacja {3,}Zadanie {3,}Prefiks'; then
    ok "zadania: odstep miedzy kolumnami >= 2 spacje; przy szerokiej liscie zapas rozlozony na odstepy (R4-3, R4-5)"
else
    bad "zadania: odstepy kolumn" "$R45N" "$R45W"
fi
# SYNCHRO: "<>" nie "<" (rekord mowi, linia crona nie umie) + F2 GRUPOWANIE
# ============================================================================
# UWAGA 4 (wlasciciel, 2026-09-24): szczebel plaski (pobranie + porzadki w JEDNEJ sekcji)
# mial w F2 tylko "pobranie". Porzadki z WLASNEJ linii zadania (tag "(sx-a)"), a linia
# porzadkow sasiedniego datasetu z tego samego bloku ("(sx-b)", inny harmonogram) nie wchodzi.
FP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs-flatprune.json" --monitors "$FIX/monitors-group.json" --screen zadania --width 200 2>&1)"
FPD="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs-flatprune.json" --monitors "$FIX/monitors-group.json" --screen zadania --width 200 2>&1)"
if hasE "$FP" '^║ sx +lokalny prune +automated ' && hasE "$FPD" 'Kiedy +co godzinę \(:21\)' && hasE "$FPD" 'Trzyma +168 godz\.' && ! hasE "$FPD" 'Kiedy +co godzinę \(:17\)' \
   && [ "$(printf '%s\n' "$FP" | grep -c '^║ .*lokalny prune')" -eq 1 ]; then
    ok "zadania: szczebel plaski pokazuje WLASNE porzadki (harmonogram z jego linii delsnaps), bez cudzych z bloku (uwaga 4: pve9-synchro)"
else
    bad "zadania: porzadki szczebla plaskiego (uwaga 4)" "$FP"
fi
# Atrapa relacji: sync-test ma TRZY linie crona identyczne poza zakresem (a/b/c,
# ten sam harmonogram) plus czwarta pod INNYM harmonogramem (d) -- ta czwarta
# NIE ma sie zlaczyc. backup-test to relacja BEZ rekordu synchro (mode
# nieobecny), zeby pokazac, ze "<" zostaje, kiedy rekord nie mowi "sync".
GJ="$FIX/jobs-group.json"; GS="$FIX/status-group.json"; GM="$FIX/monitors-group.json"
G="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --width 200 2>&1)"
GR="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen relacje --width 200 2>&1)"
if [ "$(printf '%s\n' "$G" | grep -cE '^║ sync-test ')" -eq 2 ] && hasE "$G" '^║ backup-test +pobranie +automated_hourly ' \
    && hasE "$G" 'Kierunek +pve20<>192\.168\.28\.50' && hasE "$G" 'Zakres +3 datasetów'; then
    ok "zadania: F2 -- synchro ma w panelu '<>' mimo ze KAZDA linia crona jest pull; trzy zakresy pod tym samym zadaniem to JEDEN wiersz (Zakres: 3), czwarty (inny harmonogram) NIE laczy sie"
else
    bad "zadania: F2 grupowanie i symbol synchro" "$G"
fi
if has "$G" '3 datasetów w hdd/backups/192.168.28.50/hdd/lab: a, b, c' \
    && ! has "$G" 'zakres 1' && ! has "$G" 'zakres 2'; then
    ok "zadania: panel wiersza x3 -- JEDNA linia 'zakres' z liczba i wszystkimi trzema datasetami (R3-3: nie 'zakres N' per dataset)"
else
    bad "zadania: panel grupy" "$G"
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
GRV="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GSV" --jobs "$GJ" --monitors "$GM" --screen relacje --width 200 2>&1)"
if grep -q '10.98.0.2:22' "$GSV" && hasE "$GRV" '^║ backup-test .*<10\.98\.0\.2 ' && ! hasE "$GRV" '^║ backup-test .*192\.168\.28\.60' \
   && hasE "$GR" '^║ backup-test .*<192\.168\.28\.60 '; then
    ok "relacje: Kierunek pokazuje adres, przez ktory relacja chodzi teraz (po zmianie adresu: 10.98.0.2, nie stary peer_host)"
else
    bad "relacje: Kierunek po zmianie adresu" "$(printf '%s\n' "$GRV" | grep 'backup-test' | head -2)" "$(printf '%s\n' "$GR" | grep 'backup-test' | head -1)"
fi
rm -f "$GSV"
# R3-3: przy malym terminalu (30 wierszy) 'harmonogram' MA byc widoczny, mimo
# ze zakres grupy jest jedna dluga linia -- puste linie miedzy grupami.
G30="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --width 200 --height 30 2>&1)"
if has "$G30" '3 datasetów w' && hasE "$G30" 'Kiedy +co godzinę'; then
    ok "zadania: panel grupy przy --height 30 -- 'Zakres' jedna linia, 'Kiedy' wciaz widoczne"
else
    bad "zadania: panel grupy przy malym terminalu" "$G30"
fi
GB_="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GJ" --monitors "$GM" --screen zadania --keys down,down --width 200 2>&1)"
if hasE "$GB_" 'Kierunek +pve20<192\.168\.28\.60' && ! hasE "$GB_" 'Kierunek +pve20<>'; then
    ok "zadania: panel kierunku backupu ma '<', synchro '<>' (rekord wygrywa z linia crona)"
else
    bad "zadania: panel kierunku synchro" "$GB_"
fi
if hasE "$GR" '^║ sync-test +lustro +pve20<>192\.168\.28\.50 ' && hasE "$GR" '^║ backup-test +backup +pve20<192\.168\.28\.60 '; then
    ok "relacje: F3 tez rysuje '<>' dla synchro (z rekordu, nie z linii crona) i '<' dla backupu"
else
    bad "relacje: symbol synchro na F3" "$GR"
fi
# BLAD BIEGU I WYRZUCENIA (2026-10-08, wlasciciel "rob 1 i 2"): monitor patrzy
# tylko na wiek kopii -- na pve10 lustro, ktore odmowilo pobrania (dzialajacy
# gosc 901), bylo "aktualne" na F2 i F3. Ostatni bieg z rc != 0 (poza 75 =
# pominiety przez blokade) daje "błąd biegu"; to, co bieg wyrzucil (P-0), panel.
GEJ="$(mktemp)"; GES="$(mktemp)"
"$PY" - "$GJ" "$GEJ" "$GES" <<'PYEOF'
import json, sys
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
json.dump({"window_days": 7, "jobs": [row("a", 0), row("b", 1), row("c", 0), row("d", 75)],
           "events": [{"label": "hourly backup (sync-test-b)", "discard_at": "", "discard": "", "error_at": "2026-09-08 13:48",
                       "error": "Refusing 'hdd/lab/b': it is the disk of guest 901, which is currently RUNNING."},
                      {"label": "hourly backup (sync-test-a)", "discard_at": "2026-09-08 12:16",
                       "discard": "hdd/lab/a: 1 snapshot(s) after @s1 that the source no longer has: p0manual",
                       "error_at": "", "error": ""}],
           "datasets": [], "volume": []}, open(sys.argv[3], "w", encoding="utf-8"))
PYEOF
GE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen zadania --width 200 --height 50 2>&1)"
if [ "$(printf '%s\n' "$GE" | grep -cE '^║ sync-test .*błąd biegu')" = 1 ] && ! hasE "$GE" '^║ backup-test .*błąd biegu'; then
    ok "zadania: wiersz z datasetem, ktorego ostatni bieg sie nie udal (b, rc=1) to 'błąd biegu'; rc=75 (d, blokada) nie; inna relacja tez nie"
else
    bad "zadania: błąd biegu na F2" "$(printf '%s\n' "$GE" | grep -E '^║ (sync|backup)-test')"
fi
if hasE "$GE" 'Błąd +2026-09-08 13:48 +[^ ]*/lab/b +rc=1' && has "$GE" 'Refusing' \
   && hasE "$GE" 'Wyrzucono +2026-09-08 12:16  hdd/lab/a: 1 snapshot' \
   && has "$GE" 'błędów 1   w 3 zadaniach'; then
    ok "zadania: panel wiersza mowi, ktory dataset i dlaczego (blad z dziennika) oraz co bieg wyrzucil z kopii"
else
    bad "zadania: panel błąd/wyrzucono" "$(printf '%s\n' "$GE" | grep -E 'Błąd|Wyrzuc|błędów')"
fi
GER="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$GS" --jobs "$GEJ" --monitors "$GM" --stats "$GES" --screen relacje --width 200 2>&1)"
if hasE "$GER" '^║ sync-test .*błąd biegu' && ! hasE "$GER" '^║ backup-test .*błąd biegu'; then
    ok "relacje: relacja z nieudanym ostatnim biegiem jest na F3 'błąd biegu', nie 'aktualne'"
else
    bad "relacje: błąd biegu na F3" "$(printf '%s\n' "$GER" | grep -E '^║ (sync|backup)-test')"
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
if has "$Z" 'zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' && has "$Z" 'hdd/backups/192.168.28.99/hdd/lab/vm-101' && hasE "$Z" 'Źródło +zfsbackup' && hasE "$Z" 'Cel +hdd/backups'; then
    ok "zadania: panel pobrania -- ZRODLO zdalne i CEL lokalny w osobnych wierszach, pelne sciezki"
else
    bad "zadania: zrodlo/cel w panelu" "$Z"
fi
ZP="$(screen zadania down)"
ZP="$(screen zadania down --width 160)"
if hasE "$ZP" 'Cel +hdd/backups/192.168.28.99/hdd/lab/vm-101' && ! hasE "$ZP" 'Źródło +'; then
    ok "zadania: porzadki maja tylko CEL (to, co przycinaja)"
else
    bad "zadania: porzadki zrodlo/cel" "$ZP"
fi
ZH2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --keys down,down 2>&1)"
# down,down: widok domyslny grupuje wiersze relacji -- oba "(bez rel.)" sa pierwsze
ZH2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --keys down,down --width 160 2>&1)"
if has "$ZH2" 'hdd/vm-disks/subvol-100-disk-0' && has "$ZH2" 'pve9:hdd/backups' && hasE "$ZH2" 'Źródło +hdd/vm-disks'; then
    ok "zadania: dla WYSYLKI zrodlo jest tutaj, a cel u peera"
else
    bad "zadania: wysylka zrodlo/cel" "$ZH2"
fi
ZH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --width 120 2>&1)"
if hasE "$ZH" '^║ pve9 +wysyłka ' && hasE "$ZH" '^║ pve1 +pobranie ' && hasE "$ZH" '^║ \(bez rel\.\) +kopia '; then
    ok "zadania: wysylka, pobranie i kopia na hoscie w liscie; zadanie bez etykiety mowi '(bez rel.)' (kierunek w panelu, U21)"
else
    bad "zadania: trzy kierunki na hostA" "$ZH"
fi
ZE="$(screen zadania enter --height 80)"
if has "$ZE" '╔═ Zadanie: lab-vm101 ' && has "$ZE" 'zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' && has "$ZE" 'hdd/backups/192.168.28.99/hdd/lab/vm-101' \
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
if hasE "$ZG" '^║ ghost +strażnik bez zadania' && has "$ZG" 'aktualne'; then
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
if has "$A" 't wykonaj   w wyłącz na źródle   Tab do linii poleceń' && ! hasE "$A" '║ *[a-z] = ' && has "$B" 'POTWIERDZENIE: Wyłącz relację lab-ct201' \
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
if grep -q "pause-client lab-ct201 '--reason=z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ] && has "$A" '╔═ WYJŚCIE: Wstrzymaj relację lab-ct201 ═' && has "$A" '[atrapa]'; then
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
# R4-1 (wlasciciel 2026-09-24): F4 na F3 to OKNO Transfery, nie pauza --
# klawisze F1-F6 sa zawsze glownymi oknami; pauza jest na F7.
A="$(act F4)"
if has "$A" '╔═ Historia transferów' && ! has "$A" 'POTWIERDZENIE' && [ ! -s "$XL" ]; then
    ok "akcje: F4 na ekranie Relacje przelacza na Historie (R4-1), nie wstrzymuje relacji"
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
if has "$A" '╔═ Eksport relacji lab-ct201 ═' && has "$A" "$RDP" && has "$A" 'lab-ct201.export.json_' && has "$A" 'nadpisany'    && has "$A" 'Enter zapisz' && ! has "$A" 'Enter dalej'; then
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
# F11 ODZYSK DANYCH (właściciel 2026-10-18): odzysk to osobny ekran główny -- nie 'p'
# obok 'e zmień' w oknie relacji ani F9 na Replice ("ktoś może się machnąć").
# Enter na relacji -> restore NAZWA --ask, na wierszu 'z dysku' -> restore --from-copy --ask
# (te same okna whiptail co wcześniej). 'p' w oknie relacji niczego już nie robi.
od() {   # <keys> -> ekran F11; dziennik w $XL
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen odzysk --keys "$1" 2>&1
}
A="$(od "")"
if has "$A" '╔═ Odzysk danych na pve10' && hasE "$A" '^║ lab-ct201 ' && hasE "$A" '^║ z innego dysku +nośnik' && has "$A" 'duplikat -- odzysk' && has "$A" '[Datasety]' \
   && has "$A" '11Odzysk' && has "$A" '12Wyj' && has "$A" '10Ust' && ! has "$A" '10Wyj'; then
    ok "odzysk: F11 to ekran glowny -- relacje z kopia i wiersz 'z innego dysku', panel odzysku, zakladka Datasety; na pasku 11Odzysk i 12Wyjście, bez F10"
else
    bad "odzysk: ekran F11" "$A"
fi
A="$(od enter)"
if grep -Eq "zfs-backup.sh'? restore [a-z0-9-]+ --ask\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "odzysk: Enter na relacji oddaje terminal oknu 'Przywróć' (restore NAZWA --ask)"
else
    bad "odzysk: Enter na relacji" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od end,enter)"
if grep -Eq "zfs-backup.sh'? restore --from-copy --ask\$" "$XL"; then
    ok "odzysk: Enter na 'z dysku' oddaje terminal oknu 'Przywróć z dysku' (restore --from-copy --ask)"
else
    bad "odzysk: Enter na z dysku" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
# CHUDY ODZYSK (2026-10-18): F7 na F11 = "Przeglądaj kopię" -- okna browse --ask
# (migawka RO + mc); na wierszu 'z dysku' -- browse --any --ask.
A="$(od F7)"
if grep -Eq "zfs-backup.sh'? browse [a-z0-9-]+ --ask\$" "$XL" && [ "$(grep -c . "$XL")" = 1 ]; then
    ok "odzysk: F7 na relacji oddaje terminal oknu 'Przeglądaj kopię' (browse NAZWA --ask)"
else
    bad "odzysk: F7 na relacji" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$(od end,F7)"
if grep -Eq "zfs-backup.sh'? browse --any --ask\$" "$XL"; then
    ok "odzysk: F7 na 'z dysku' -- browse --any --ask (dowolny dataset tego hosta)"
else
    bad "odzysk: F7 na z dysku" "$(cat "$XL")"
fi
A="$(od "" | tail -1)"
if has "$A" 'Przeglądaj'; then
    ok "odzysk: pasek F11 podpisuje F7 Przeglądaj"
else
    bad "odzysk: pasek F11" "$A"
fi
if grep -q '^        browse)$' "$REPO/zfs-backup.sh" && grep -q 'tui/browse.sh' "$REPO/zfs-backup.sh" && bash -n "$REPO/tui/browse.sh" \
   && grep -q 'mount -t zfs -o ro' "$REPO/tui/browse.sh" && grep -q 'trap cleanup EXIT' "$REPO/tui/browse.sh"; then
    ok "odzysk: browse --ask prowadzi do tui/browse.sh; montaż -o ro, sprzątanie w trap EXIT"
else
    bad "odzysk: browse -> tui/browse.sh" "brak przekazania albo montażu ro"
fi
A="$(act down,enter,p)"
if [ ! -s "$XL" ] && ! has "$A" 'p przywróć'; then
    ok "odzysk: 'p' w oknie relacji niczego nie uruchamia i stopka o nim nie mówi (odzysk jest na F11)"
else
    bad "odzysk: p w oknie relacji" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
: > "$XL"
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --exec-log "$XL" --screen nosniki --keys F9 2>&1)"
if [ ! -s "$XL" ] && has "$A" 'przywracanie z dysku jest teraz na F11 Odzysk'; then
    ok "odzysk: F9 na F6 niczego nie uruchamia, mowi gdzie jest odzysk (F11)"
else
    bad "odzysk: F9 na F6" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen nosniki --width 80 2>&1 | grep 'Pomoc' | tail -1)"
if has "$A" '11Odzysk' && has "$A" '12Wyj' && ! has "$A" '9Odzysk'; then
    ok "akcje: pasek F6 przy 80 kolumnach -- bez F9, z 11Odzysk i 12Wyj(ście/dź)"
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
A="$(act down,enter)"
# Odzysk przeszedł na F11 (2026-10-18): w stopce tylko 'e zmień'.
if has "$A" 'e zmień   Esc zamyka'; then
    ok "akcje: ...okno relacji mowi o tym w stopce ('e zmień'), bez 'p przywróć'"
else
    bad "akcje: stopka okna relacji bez 'e'" "$(printf '%s' "$A" | tail -3)"
fi
# DOKOŃCZ (paczka A finiszu, 2026-10-18): relacja nie-aktywna dostaje w oknie 'd' =
# następny krok cyklu jako zwykłe potwierdzenie; 't' go wykonuje. Aktywna -- nic.
A="$(act enter)"
B="$(act enter,d)"
if has "$A" 'd dokończ   e zmień' && has "$B" 'POTWIERDZENIE: Dokończ relację duplikat' && has "$B" 'seed duplikat --yes' && [ ! -s "$XL" ]; then
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
if [ ! -s "$XL" ] && ! has "$A" 'POTWIERDZENIE' && ! has "$A" 'd dokończ'; then
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
if has "$WT" 'co: co godzinę (:56)   stempel automated_hourly_   trzyma 24' && has "$WT" 'co: co dobę 02:06   stempel automated_daily_   trzyma 7' \
   && has "$WT" 'trzyma 12   co: co godzinę (:36)' && has "$WT" 'trzyma 3   co: co dobę 02:46' && ! has "$WT" 'co: co godzinę (:01)'; then
    ok "okno: rytm i retencja KAZDEGO szczebla, z polami szczebla sekcji (send_/prune_schedule_<szablon>) przed szablonem"
else
    bad "okno: rytm per szczebel" "$(printf '%s' "$WT" | grep -E 'pobranie|prune|co:' | head -8)"
fi
W="$(screen relacje down,enter --height 80)"
if has "$W" '╔═ Relacja lab-ct201 ═'; then
    ok "okno: Enter na wierszu otwiera okno relacji na wierzchu"
else
    bad "okno: otwarcie" "$W"
fi
if hasE "$W" 'Cele [(]1[)] +hdd/backups/192.168.28.99/hdd/lab/ct-201' && ! has "$W" 'Lądowisk' && ! hasE "$W" '║ Cel  ' && hasE "$W" 'Źródła [(]1[)] +zfsbackup-pve10@192.168.28.99:hdd/lab/ct-201' \
        && has "$W" 'co obejmuje' && has "$W" 'jak długo trzyma' && has "$W" 'czy działa' && has "$W" 'komendy' \
        && ! has "$W" 'W CRONIE' && ! has "$W" '[ Opis ]'; then
    ok "okno: szczegoly -- zrodla z rekordu, JEDEN wiersz 'Cele (N)' (R5-3, MANAGED_DATASETS), grupy pytaniami operatora, bez zakladek (R4-7)"
else
    bad "okno: zakres/Opis" "$W"
fi
W2="$(screen relacje down,enter --height 60)"
if has "$W2" 'zfs-backup.sh pause-client lab-ct201' && ! has "$W2" 'resume-client'; then
    ok "okno: komendy CLI dla relacji AKTYWNEJ: pause-client, bez resume-client"
else
    bad "okno: komendy dla stanu active" "$W2"
fi
# JEDNO OKNO (R4-7, zamiast zakladek R3-2): szczegoly, pod nimi CONFIG, potem
# CRON -- w tej kolejnosci. LINIE CRONA PO ETYKIECIE (linia snapget dla pobrania
# nazywa zdalne zrodlo i RODZICA ladowiska, nigdy samo ladowisko -- dopasowanie
# po zakresie jej nie widzialo, zmierzone na pve10 2026-09-09; klucz drugi:
# -L <etykieta>) sa w sekcji CRON.
WCFG="$(screen relacje down,enter --height 200)"
LCFG=$(printf '%s\n' "$WCFG" | grep -n '── CONFIG ' | head -1 | cut -d: -f1)
LCRN=$(printf '%s\n' "$WCFG" | grep -n '── CRON ' | head -1 | cut -d: -f1)
LKOM=$(printf '%s\n' "$WCFG" | grep -n '║ komendy' | head -1 | cut -d: -f1)
if [ -n "$LCFG" ] && [ -n "$LCRN" ] && [ -n "$LKOM" ] && [ "$LKOM" -lt "$LCFG" ] && [ "$LCFG" -lt "$LCRN" ]; then
    ok "okno: kolejnosc sekcji -- szczegoly, CONFIG, CRON (R4-7, decyzja wlasciciela)"
else
    bad "okno: kolejnosc sekcji" "komendy=$LKOM config=$LCFG cron=$LCRN" "$WCFG"
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
WCG="$(screen relacje down,enter --width 160 --height 300 | sed -n '/── CRON /,/konto:/p')"
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
WCFGSEED="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --screen relacje --keys enter --height 80 --width 100 2>&1)"
if has "$WCFGSEED" 'configu jeszcze nie ma -- powstanie przy aktywacji' && has "$WCFGSEED" 'zfs-backup.sh activate duplikat'; then
    ok "okno: CONFIG relacji bez zainstalowanego configu (seeding) mowi to, nie zgaduje"
else
    bad "okno: CONFIG relacji w zasiewie" "$WCFGSEED"
fi
WP="$(screen relacje down,down,down,down,enter --height 260)"
if has "$WP" '── CONFIG ' && has "$WP" '[dataset:hdd/backups/192.168.28.99/hdd/lab/vm-101]' \
        && has "$WP" 'send_schedule = 24 * * * *' && has "$WP" 'src = zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' \
        && has "$WP" '[prune:hdd/backups/192.168.28.99/hdd/lab/vm-101]' && has "$WP" 'prune_schedule = 44 * * * *' \
        && has "$WP" '[template:profile__default__keep_monthly]' && has "$WP" 'retain = -M12'; then
    ok "okno: CONFIG relacji -- sekcje [dataset:]/[prune:] i szablony UZYTE (use_template), werbatim z show-config"
else
    bad "okno: CONFIG -- sekcje relacji lab-vm101" "$WP"
fi
WS="$(screen relacje enter --height 60)"
if has "$WS" 'zfs-backup.sh activate duplikat'; then
    ok "okno: relacja w zasiewie nazywa 'activate' (wznawialne dokonczenie cyklu)"
else
    bad "okno: komendy dla stanu seeding" "$WS"
fi
WPZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down,enter --height 120 2>&1)"
if has "$WPZ" 'zfs-backup.sh resume-client lab-srv-b' && ! has "$WPZ" 'pause-client lab-srv-b'; then
    ok "okno: relacja wstrzymana nazywa resume-client, nie pause-client"
else
    bad "okno: komendy dla pauzy" "$WPZ"
fi
WE="$(screen relacje down,enter,esc)"
if has "$WE" 'Relacje na kolektorze pve10' && ! has "$WE" '╔═ Relacja lab-ct201'; then
    ok "okno: Esc zamyka okno i wraca do listy"
else
    bad "okno: Esc" "$WE"
fi
if hasE "$(screen relacje down,enter)" 'Esc zamyka   strzałki/PgUp/PgDn przewijają   [0-9]+-[0-9]+ z [0-9]+'; then
    ok "okno: stopka mowi, jak wyjsc i ile jest do przewiniecia"
else
    bad "okno: stopka" "$W"
fi

# ============================================================================
# TRANSFERY
# ============================================================================
T="$(screen transfery)"
if has "$T" '╔═ Historia transferów na pve10 (14)   biegnie teraz: 0' && ! has "$T" 'W toku'; then
    ok "transfery: JEDNA lista (U21) -- tytul liczy wpisy i mowi, ile biegnie teraz"
else
    bad "transfery: ramki" "$T"
fi
T120="$(screen transfery "" --width 120)"
if hasE "$T120" '^║ [0-9:]+ +lab-srv-b +hdd/lab/srv-b/www +przyrost\. +OK +0 s +- +║'; then
    ok "transfery: wiersz = kiedy, relacja, dataset (bez @migawki), tryb, wynik, czas, dane"
else
    bad "transfery: wiersz transferu" "$T120"
fi
if hasE "$T" 'Poprzednia +automated_hourly' && hasE "$T" 'Start / koniec +2026-09-09'; then
    ok "transfery: panel -- migawka, poprzednia, zrodlo i cel, start/koniec; bez powtorek z listy (U21)"
else
    bad "transfery: niemierzalne" "$T"
fi
# NOTE 8 (wlasciciel, 2026-09-24), R4-2: F7 chowa/pokazuje transfery relacji,
# ktorych juz nie ma -- z 14 zapisow fikstury 6 ma etykiete "labsp"/"lab1"/""
# (brak rekordu w status.json), 8 nalezy do zywych relacji. Listwa (dopisek
# 'F7 ...') potrzebuje szerszego terminala, zeby sie zmiescic, a panel ma stac obok (prog 150) -- stad --width 160.
TW130="$(screen transfery "" --width 160)"
if has "$TW130" 'F7 Ukryj usunięte' && ! has "$TW130" 'F7 Pokaż usunięte' && ! has "$TW130" 'F7 ukryj usunięte'; then
    ok "transfery: domyslnie POKAZANE (dziennik transferow), pasek mowi 'F7 Ukryj usunięte', ramka bez F"
else
    bad "transfery: domyslny stan F7" "$TW130"
fi
TU="$(screen transfery F7 --width 160)"
if has "$TU" 'Historia transferów na pve10 (8) -- bez usuniętych relacji' && ! has "$TU" '(bez relacji)' && has "$TU" 'F7 Pokaż usunięte'; then
    ok "transfery: F7 chowa transfery bez zywej relacji (14 -> 8), tytul mowi, listwa odwraca podpis"
else
    bad "transfery: F7 chowa" "$TU"
fi
TUU="$(screen transfery F7,F7 --width 160)"
if has "$TUU" 'Historia transferów na pve10 (14)' && has "$TUU" '(bez relacji)' && ! has "$TUU" 'bez usuniętych relacji'; then
    ok "transfery: drugie F7 pokazuje je znowu"
else
    bad "transfery: F7 pokazuje znowu" "$TUU"
fi
# R4-2: LITERA TO TEKST. 'u' w rundzie 3 bylo zielone w tym tescie i martwe na
# zywo: --keys podawal 'u' prosto do UI.key, a petla curses oddaje je linii
# polecen. --keys idzie teraz ta sama droga (live_key_name), wiec 'u' ma NIC
# nie schowac i stanac w linii polecen.
TUL="$(screen transfery u --width 160)"
if has "$TUL" 'Historia transferów na pve10 (14)' && ! has "$TUL" 'bez usuniętych relacji' && has "$TUL" '$ u_ '; then
    ok "transfery: 'u' to TEKST linii polecen, nie skrot (R4-2: droga --keys = droga petli curses)"
else
    bad "transfery: 'u' jako tekst" "$TUL"
fi
# R4-1/R4-2 PRZEZ PRAWDZIWA PETLE CURSES (pty), nie przez --keys: runda 3
# miala 'u' i 's' zielone tutaj i martwe na zywo. Klawisze ida jako bajty
# terminala (ESC [ 18 ~ = F7, ESC [ 19 ~ = F8); kazdy blok to to, co program narysowal po nim.
PK="$("$PY" "$REPO/test/tui/pty-keys.py" "$TUI" 's,F8,F3,F4,u,F7,ctrl-r' -- --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" 2>&1)"; PKRC=$?
pkb() { printf '%s\n' "$PK" | awk -v k="=== $1" -v n="$2" '$0 ~ /^=== / { i++; on = ($0 == k && i == n) ; next } on'; }
if [ "$PKRC" -eq 2 ]; then
    echo "SKIP pty: brak modulu pty (Windows) -- klawisze przez petle curses sprawdza CI"
elif has "$(pkb s 2)" 's_' && ! has "$(pkb s 2)" 'oś czasu' && has "$(pkb F8 3)" 'oś czasu' \
     && has "$(pkb F4 5)" 'Historia transferów' && ! has "$(pkb F4 5)" 'POTWIERDZENIE' \
     && has "$(pkb u 6)" 'u_' && ! has "$(pkb u 6)" 'bez usuniętych' && has "$(pkb F7 7)" 'bez usuniętych relacji'      && has "$(pkb ctrl-r 8)" 'odświeżam'; then
    ok "pty: 's' i 'u' to tekst linii, F8 sortuje F2 (X9), F7 chowa usuniete na F4, F4 na F3 otwiera Transfery (petla curses, R4-1/R4-2)"
else
    bad "pty: klawisze przez petle curses" "$PK"
fi
# F11 / F12 / Tab PRZEZ PETLE CURSES (2026-10-18): ESC [ 23 ~ otwiera Odzysk, Tab
# przenosi do linii polecen (strzalka w gore = historia), ESC [ 24 ~ konczy program.
PK2="$("$PY" "$REPO/test/tui/pty-keys.py" "$TUI" 'F11,tab,F12' -- --offline --utf8 --now "$NOW" $ALL 2>&1)"; PK2RC=$?
pk2() { printf '%s\n' "$PK2" | awk -v k="=== $1" '$0 ~ /^=== / { on = ($0 == k); next } on'; }
if [ "$PK2RC" -eq 2 ]; then
    echo "SKIP pty F11/F12: brak modulu pty (Windows) -- sprawdza CI"
elif has "$(pk2 F11)" 'Odzysk danych na pve10' && true \
     && printf '%s\n' "$PK2" | grep -qx '=== exited'; then
    ok "pty: F11 (ESC[23~) otwiera Odzysk, Tab, F12 (ESC[24~) konczy program rc=0 (petla curses)"
else
    bad "pty: F11/F12 przez petle curses" "rc=$PK2RC" "$PK2"
fi
# Odswiez: F9 -> F5 (R4-2) -> Ctrl-R (2026-10-09: F5 to ekran Szablony, uwaga 24).
TR="$(screen zadania ctrl-r --width 160)"
if has "$TR" 'odświeżono' && has "$TR" 'Ctrl-R Odśwież' && ! has "$TR" 'F5 Odśwież' && has "$TR" 'F5 Szablony'; then
    ok "listwa: Ctrl-R odswieza i tak jest podpisane; F5 to Szablony"
else
    bad "listwa: Ctrl-R odswiez" "$TR"
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
if has "$TF" '╔═ Historia transferów' && ! has "$TF" '[F4'; then
    ok "transfery: F4 z innego ekranu przelacza (aktywne okno na pasku kolorem, bez nawiasow)"
else
    bad "transfery: F4" "$TF"
fi
TW="$(screen transfery down,enter)"
if has "$TW" '╔═ transfer lab-srv-b ═' && hasE "$TW" 'Migawka +automated_hourly' && hasE "$TW" 'Źródło +192\.168\.28\.99:hdd/lab/srv-b/db'; then
    ok "transfery: Enter otwiera szczegoly wiersza pod kursorem jako okno"
else
    bad "transfery: Enter" "$TW"
fi

# KOLUMNA KIEDY NIE UCINA SIE. Wpis z innego dnia niz "dzis" (fmt_when_short:
# DD.MM HH:MM, bez roku) plus czas trwania (45 min) mial sie NIE zmiescic w
# starej stalej szerokosci 16 i wychodzil jako "...22:0…" (owner brief, runda 2).
OLD100="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --progress "$FIX/progress-older.json" --screen transfery --width 100 2>&1)"
OLD120="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --progress "$FIX/progress-older.json" --screen transfery --width 120 2>&1)"
if hasE "$OLD100" '[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2} ' && has "$OLD100" '45 min' && ! has "$OLD100" '…' \
    && hasE "$OLD120" '[0-9]{2}\.[0-9]{2} [0-9]{2}:[0-9]{2} ' && has "$OLD120" '45 min' && ! has "$OLD120" '…'; then
    ok "transfery: Kiedy starszego wpisu -- DD.MM HH:MM i czas trwania w osobnej kolumnie, bez wielokropka, przy 100 i 120 kolumnach"
else
    bad "transfery: kolumna Kiedy starszego wpisu" "$OLD100" "$OLD120"
fi

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
if hasE "$SO3" '^║ som +migawki zdalne +→ 10\.0\.0\.9 +działa ' && hasE "$SO3" 'Kopia +brak -- migawki i ich' \
   && hasE "$SO3Z" 'migawka +pve10_automated_daily +co dobę 01:49' && hasE "$SO3Z" 'migawka +pve10_automated_hourly +co godzinę' \
   && ! printf '%s\n' "$SO3" | grep -E '^║ som .*(pve10<|←)' | grep -q .; then
    ok "relacje: relacja snaponly -- '→ <peer>', typ 'migawki zdalne', w panelu 'Kopia: brak', w zakladce Zadania migawki z rodzina i harmonogramem"
else
    bad "relacje: relacja snaponly" "$SO3" "$SO3Z"
fi
# Dolny panel (wlasciciel 2026-10-18, "nie rozumiem tej listy"): bez kopii wiersz to
# sam dataset i host, nie surowy zakres "konto@host:ds -> bez kopii".
if hasE "$SO3" '^║ hdd/solab   na 10\.0\.0\.9 +aktualne' && has "$SO3" 'som: [Datasety]  Zadania' \
   && hasE "$SO3" '^║ Dataset +Migawki +Szczeble' && ! printf '%s\n' "$SO3" | grep -qE 'zfsbackup-pve10@|bez kopii +aktualne'; then
    ok "relacje: dataset snaponly -- wiersz 'dataset   na <host>' z monitorem 'aktualne', kolumny Dataset/Migawki"
else
    bad "relacje: monitor pary snaponly" "$SO3"
fi
SOE="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen relacje --width 120 --height 34 --keys enter 2>&1)"
if has "$SOE" 'e zmień   Esc zamyka   strzałki/PgUp/PgDn przewijają' && ! has "$SOE" 'p przywróć' && ! hasE "$SOE" 'Zmiana +'; then
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
SO2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $SOA --screen zadania --width 160 --height 50 2>&1)"
if [ "$(printf '%s\n' "$SO2" | grep -cE '^║ som +migawka .*aktualne')" = 2 ]; then
    ok "zadania: zadania snaponly to 'migawka' z wlasna rodzina"
else
    bad "zadania: zadania snaponly" "$SO2"
fi
rm -rf "$SOD" "$SOL"

# ============================================================================
# NOSNIKI
# ============================================================================
N="$(screen nosniki)"
# X11 (2026-10-12): kolumna Rodzaj po nazwie; sciezka sejf-b obcina sie wczesniej.
if hasE "$N" '^║ sejf-a +W SEJFIE +brak +co dobę 02:30 +║' && hasE "$N" '^║ sejf-b +W SEJFIE +brak +po włożeniu +║'; then
    ok "nosniki: wiersz = replika, stan nosnika SLOWEM, kiedy ostatnia aktualna kopia (Kopia z), harmonogram slowami (U21)"
else
    bad "nosniki: wiersze" "$N"
fi
# KONTROLA CZYTELNIKA: sejf-b nie ma linii `media` (--fixed). Stary list-replicas
# zwracal media="yes", recursive="latest" -- pola przesuniete o jedno przez
# IFS=tab. Fikstura pochodzi z NAPRAWIONEGO czytelnika i ten ekran to przypina.
NB="$(screen nosniki down --width 160)"
NBT="$(screen nosniki down,tab --width 160)"
if has "$NBT" 'sejf-b -- dataset' && hasE "$NBT" 'Z dziećmi +tak' && hasE "$NBT" 'Historia +latest'; then
    ok "nosniki: dataset repliki --fixed ma rekursje i historie na SWOICH miejscach (kontrola przesuniecia pol list-replicas)"
else
    bad "nosniki: pola repliki --fixed" "$NBT"
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
Z2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $RALL --screen zadania --width 200 --height 60 2>&1)"
if hasE "$Z2" '^║ sejf-a +replika ' && hasE "$Z2" '^║ sejf-b +replika .*po włożeniu'; then
    ok "zadania: repliki sa wierszami F2 (zadanie 'replika', 'po włożeniu' bez godziny)"
else
    bad "zadania: wiersze replik" "$(printf '%s' "$Z2" | grep -E 'sejf|replika')"
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
Z3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$RMN" --replicas "$P10/replicas.json" --screen zadania --width 200 --height 60 2>&1)"
if hasE "$Z3" '^║ sejf-a +replika .*spóźnione' && hasE "$Z3" '^║ sejf-b +replika .*bez monitora'; then
    ok "zadania: wiersz repliki bierze werdykt z JEJ monitora (sejf-a spóźniona), bez monitora zostaje 'bez monitora' (sejf-b)"
else
    bad "zadania: werdykt repliki z monitora" "$(printf '%s' "$Z3" | grep -E 'sejf')"
fi
rm -f "$RMN"
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
# X14: wiersz bez linii w cronie (strażnik, replika tylko po włożeniu) -- komunikat nazywa
# wszystkie trzy przypadki. Wiersz "bez monitora" repliki sejf-b nie ma linii w cronie.
A="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/monitor-orphan.json" --screen zadania --keys F7 --width 200 2>&1)"
if has "$A" 'strażnik albo replika, bez harmonogramu, lub osierocony wpis' && has "$A" 'F7 Uruchom teraz F8 Sortuj'; then
    ok "zadania: X14 -- komunikat nazywa strażnika, replikę bez harmonogramu i osierocony wpis; listwa F7 Uruchom teraz / F8 Sortuj (X9)"
else
    bad "zadania: X14 komunikat" "$(printf '%s' "$A" | tail -4)"
fi
# X11 (wlasciciel 2026-10-12): replika na liscie i w panelu mowi, CO TRAFIA NA DYSK --
# kolumna Rodzaj (historia / zdjecia xN), panel: Rodzaj, Na dysku (z przykladem), Szyfrowane.
F6R="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --screen nosniki --width 200 --height 40 2>&1)"
if hasE "$F6R" '║ Replika +Nośnik +Kopia z +Kiedy' && hasE "$F6R" 'Rodzaj +własne zdjęcia' \
   && hasE "$F6R" 'Na dysku +2 ostatnie zdjęcia = ok\. 2 dni wstecz' && hasE "$F6R" 'Szyfrowane +nie'; then
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
if has "$A" 'Replika sejf-a -- bieg teraz' && grep -q "run-replicas --name=sejf-a" "$XL" && ! has "$A" 'nie ma linii w cronie'; then
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
if has "$A" 'e zmień replikę'; then
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
if has "$S1" 'W SLOCIE -- kopia aktualna z 2026-10-08 20:46' && has "$S2" 'W SLOCIE -- brak kopii' && has "$S1" 'Kopia z'; then
    ok "nosniki: dysk w slocie mowi, czy kopia na nim jest aktualna (z czasem) albo ze kopii brak; kolumna 'Kopia z'"
else
    bad "nosniki: w slocie + kopia" "$(printf '%s\n' "$S1" | grep -E 'SLOCIE|Kopia')" "$(printf '%s\n' "$S2" | grep -E 'SLOCIE')"
fi
rm -f "$RSL"
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
for sc in zadania relacje transfery nosniki; do
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
if [ "$(cat "$XL")" = "ls -l" ] && has "$C" '[atrapa] nie uruchomiono, komenda zapisana do dziennika testu: ls -l'; then
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
   && printf '%s\n' "$C" | tail -1 | grep -q '12Wyj\|F12' && has "$C" '═ t wykonaj   ' && has "$C" 'Tab do linii poleceń   Esc wróć'; then
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
    for sc in zadania relacje transfery nosniki; do
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
for sc in zadania relacje transfery nosniki; do
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
if hasE "$A" '^\| lab-ct201 +backup +pve10<192.168.28.99 +dzia(ł|l)a +aktualne +\|' && has "$A" 'duplikat (wg rekordu, nie crona): [Datasety]' && has "$A" '192.168.28.99:hdd/lab/vm-101 -> hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "wyglad: w ASCII te same slowa (aktualne, Zrodla) -- werdykt niesie slowo, nie tylko kolor"
else
    bad "wyglad: slowa w ASCII" "$A"
fi
HLP="$(screen relacje F1 --height 90)"
if has "$HLP" '╔═ Pomoc ═' && has "$HLP" 'bez monitora   NIKT nie pyta' && has "$HLP" 'NAJPIERW komenda bash'; then
    ok "pomoc: F1 otwiera pomoc ze slownikiem kolumny Kopie"
else
    bad "pomoc: F1" "$HLP"
fi
if has "$S" '1Pomoc2Zadania3Rel4Hist5Szabl6Repl7Uruchom8Pauza9Plik10Ust11Odzysk12Wyjdź'; then
    ok "wyglad: przy 80 kolumnach pasek miesci WSZYSTKIE klawisze F, z F11 i F12 (zapis skrocony, cyfra = F; najciasniej Hist/Szabl/Wyjdz)"
else
    bad "wyglad: listwa F" "$S"
fi
# BEZ DUBLI (wlasciciel 2026-10-09, uwaga 4: "Klawisze F sa podublowane z paska i wewnatrz
# okna"; "trzeba to zrobic poprawnie bez dubli"). Kazdy ekran, kazda szerokosc: klawisz F
# wystepuje TYLKO w ostatniej linii (pasek), a kazda akcja okna jest na pasku dokladnie raz.
NODUP=""
for _sc in zadania relacje transfery szablony nosniki; do
    for _w in 80 120 200; do
        _o="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --screen "$_sc" --width "$_w" --height 30 2>&1)"
        _body="$(printf '%s\n' "$_o" | sed '$d')"; _bar="$(printf '%s\n' "$_o" | tail -1)"
        printf '%s' "$_body" | grep -qE '(^|[^A-Za-z0-9])F([1-9]|1[0-2])([^0-9]|$)' && NODUP="$NODUP $_sc/$_w:F-w-oknie"
        case "$_sc" in
            zadania) _acts="Sortuj" ;; relacje) _acts="Uruchom Pauza" ;; transfery) _acts="sunięte" ;;
            nosniki) _acts="Uruchom" ;; *) _acts="" ;;
        esac
        # Transf/Szabl/Wyj: pelne slowo albo najciasniejszy skrot (80 kolumn, 2026-10-18).
        for _a in Pomoc Zadania Rel Hist Szabl Repl Ust Odzysk Wyj $_acts; do
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
    line, marks = m.key_bar_parts("transfery", w, m.screen_actions("transfery"))
    act = [line[a:b] for a, b, k in marks if k == "active"]
    out.append("%s:%s" % (w, "|".join(act)))
print(" ".join(out))
PYEOF
)"
if [ "$MKOUT" = "80:4Hist 120:4Historia 200:F4 Historia" ]; then
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
XT="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --progress "$BROKEN" --screen transfery 2>&1)"
XN="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --replicas "$BROKEN" --screen nosniki 2>&1)"
if has "$XT" 'błąd źródła: progress --json' && has "$XN" 'błąd źródła: list-replicas --json'; then
    ok "ujemna: kazdy z pozostalych ekranow nazywa SWOJE zepsute zrodlo (F5/monitor zniesiony razem z ekranem)"
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
n=$(cat "$NR_DIR/wt.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$NR_DIR/wt.n"
line=$(sed -n "${n}p" "$NR_DIR/answers")
[ -n "$line" ] || { echo "ATRAPA: brak odpowiedzi nr $n" >> "$NR_DIR/wt.log"; exit 255; }
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
0${T}
"; }
W17A=$(nr_run "$(w17_ans 'grant|raw')" NR_FIX="$NRE" NR_TREE="$NRTK"); W17L1="$(grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
W17B=$(nr_run "$(w17_ans 'grant')" NR_FIX="$NRE" NR_TREE="$NRTK")
W17C=$(nr_run "$(w17_ans 'grant')" NR_TREE="$NRTK"); W17L3="$(grep -F 'Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
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
import sys, json
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in d["datasets"]:
    x["own_snapshots"] = 5 if x["name"] == "hdd/test-kreator" else 0
    x["family_snapshots"] = 5 if x["name"] == "hdd/test-kreator" else 0
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
# szablon passive-flat jest na kazdym hoscie (profiles/), w fixture go nie bylo
"$PY" - "$NRC/list-profiles.json" <<'PYEOF'
import sys, json, copy
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
if not any(x.get("name") == "passive-flat" for x in d["profiles"]):
    x = copy.deepcopy(d["profiles"][0]); x["name"] = "passive-flat"; d["profiles"].append(x)
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
NRCA=$(nr_run "$(w17_ans 'grant')" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCW="$(cat "$NR/wt.log")"
"$PY" - "$NRC/list-datasets-pve9b.json" <<'PYEOF'
import sys, json
p = sys.argv[1]; d = json.load(open(p, encoding="utf-8"))
for x in d["datasets"]:
    x["family_snapshots"] = 0
json.dump(d, open(p, "w", encoding="utf-8"))
PYEOF
NRCB=$(nr_run "$(w17_ans 'grant')" NR_FIX="$NRC" NR_TREE="$NRTK"); NRCW0="$(cat "$NR/wt.log")"
if has "$NRCW" '[polecany]' && has "$NRCW" 'resztki starej relacji' && has "$NRCW" 'UWAGA ŁAŃCUCH' && has "$NRCW" 'pole Harmonogram -> passive-flat' \
   && ! has "$NRCW0" 'ŁAŃCUCH' && ! has "$NRCW0" '[polecany]' && has "$NRCB" 'CMD: '; then
    ok "new-relation: backup z magazynu kopii (nasza rodzina na zrodle) -- polecany passive-flat, UWAGA LANCUCH w podsumowaniu; reczne migawki -- bez tego"
else
    bad "new-relation: lancuch dla backupu" "$(printf '%s' "$NRCW" | grep -E 'polecany|ŁAŃCUCH' | cut -c1-200)" "$(printf '%s' "$NRCW0" | grep -E 'polecany|ŁAŃCUCH' | cut -c1-200)"
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
0${T}
"
SOWO=$(nr_run "$SOW" NR_TREE="$NRTK")
SOWP="$(grep -F 'Jak długo trzymać migawki na źródle' "$NR/wt.log" | head -1)"
if has "$SOWO" "CMD: " && has "$SOWO" " --mode=snaponly " && ! has "$SOWO" "--target=" && has "$SOWO" " --grant-remotely " \
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
if [ "$NRRC" -eq 0 ] && has "$NROUT" "CMD: --source=192.168.28.98:hdd/data,hdd/test-kreator --target=hdd/backups --profile=default --name=pve9b --exclude-child=^hdd/data/mail\$ --exclude-family=__replicate_,vzdump,__migration__ --grant-remotely --install --yes " && ! has "$NROUT" "--recursive" && ! hasE "$NROUT" 'exclude-child=[^ ]*[(|]'; then
    ok "new-relation: koszyk -- miejsca w JEDNYM --source po przecinku, odznaczone dziecko jako --exclude-child=^nazwa\$ (zakotwiczone, bez ( | -- wzorzec jedzie nieocytowany do crona)"
else
    bad "new-relation: koszyk, droga glowna" "rc=$NRRC" "$NROUT" "$(cat "$NR/err")" "$(cat "$NR/wt.log")"
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
if has "$NRTL" 'Co kopiować z 192.168.28.98?' && has "$NRTL" 'POWSTANIE' \
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
${NRT}" NR_TREE='goto:hdd,space,goto:hdd/ct/subvol-301-disk-0,space,goto:hdd/ct,space,enter')
NRTL="$(cat "$NR/tree.log" 2>/dev/null)"
# Ekran: wyjatek hdd/ct (odznaczony) wchlonal wczesniejszy wyjatek 301 -- 'pominięte: 1', nie 2.
if has "$NROUT" "CMD: --source=192.168.28.98:hdd --target=hdd/backups --profile=default --name=pve9b --exclude-child=^hdd/ct\$ --exclude-child=^hdd/ct/ --exclude-family" && [ "$(printf '%s' "$NROUT" | grep '^CMD: ' | grep -o 'exclude-child' | wc -l)" -eq 2 ] \
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
0${T}lab-ct201
0${T}
0${T}pve9b
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
0${T}
" NR_TREE="$NRTK")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/test-kreator --target=hdd/backups --profile=d30 --name=pve9b --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --grant-remotely --grant-quiesce --install --yes " \
   && grep -qF 'Nazwa zajęta' "$NR/wt.log" && [ "$(grep -c '^list-profiles' "$NR/zb.log")" -eq 1 ] && [ "$(grep -c '^status' "$NR/zb.log")" -eq 1 ]; then
    ok "new-relation: pola cel-konto -- zajeta nazwa odmowiona, z podsumowania szablon zmienia wybor (d30, U66), konto delegowane = --local-user; list-profiles i status czytane RAZ na przebieg (cofanie nie kaze czekac od nowa)"
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
if grep -F 'Podsumowanie' "$NR/wt.log" | tail -1 | grep -qF 'BACKUP: ' && grep -qF 'Konto: zfsbackup.' "$NR/wt.log" \
   && ! grep -F 'Podsumowanie' "$NR/wt.log" | tail -1 | grep -qF -- '--scrolltext'; then
    ok "new-relation: podsumowanie miesci sie BEZ przewijania (w oknie z --scrolltext Enter nie dziala, dopoki nie przejdziesz Tabem na przyciski -- zmierzone jazda po pty)"
else
    bad "new-relation: podsumowanie" "$(grep -F 'Podsumowanie' "$NR/wt.log" | tail -1 | cut -c1-600)"
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
0${T}
" NR_GRID_KEYS=space,enter NR_TREE="$NRTK")
if printf '%s' "$NROUT" | grep -qF 'Tego szczebla nie da się wyłączyć' && ! grep -q '^save-profile' "$NR/zb.log"; then
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
0${T}
0${T}pasywnie
0${T}passive
0${T}create
0${T}
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
NRLN_S="$(grep -n -F 'Podsumowanie' "$NR/wt.log" | head -1 | cut -d: -f1)"
NRLN_C="$(grep -n -F 'Nowa relacja -- podsumowanie' "$NR/wt.log" | grep -F -e '--menu' | awk -F: -v s="${NRLN_S:-0}" '$1 < s { n = $1 } END { print n }')"
NRCARD="$(sed -n "${NRLN_C:-1}p" "$NR/wt.log")"
if [ -n "$NRLN_X" ] && [ -n "$NRLN_C" ] && [ -n "$NRLN_S" ] && [ "$NRLN_X" -lt "$NRLN_C" ] && [ "$NRLN_C" -lt "$NRLN_S" ] \
   && has "$NRCARD" '--default-item ~ create ~'; then
    ok "new-relation: podsumowanie kreatora z kursorem na create pojawia sie PO 'Ustawienia dodatkowe' (Zaawansowane) i PRZED 'Podsumowanie' (U66)"
else
    bad "new-relation: karta przed podsumowaniem" "extra=$NRLN_X karta=$NRLN_C podsumowanie=$NRLN_S" "$(printf '%s' "$NRCARD" | cut -c1-300)"
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
0${T}
" NR_TREE="$NRTK|goto:hdd,enter")
if has "$NROUT" " --target=hdd " && ! grep -qF 'Dokąd -- przeglądaj ~ --ok-button' "$NR/wt.log" \
   && "$PY" - "$NR/tree-spec.last" <<'PYEOF'
import sys, json
s = json.load(open(sys.argv[1], encoding="utf-8")); names = [d["name"] for d in s["datasets"]]
ok = s.get("single") is True and "hdd" in names and "hdd/backups" in names \
     and not any(n.startswith("hdd/backups/192.168.28.99") for n in names) and "ukryto" in s.get("legend", "")
sys.exit(0 if ok else 1)
PYEOF
then
    ok "new-relation: Przegladaj w kroku Dokad = drzewo jednej pozycji (U68), kopie innych relacji ukryte i policzone, wybor idzie do --target"
else
    bad "new-relation: Przegladaj = drzewo" "$NROUT" "$(cat "$NR/tree-spec.last" 2>/dev/null | cut -c1-400)"
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
0${T}
" NR_TREE='goto:hdd/backups/192.168.28.99/hdd/lab,space,enter'); NRRC=$?
NRSI="$(grep -E -- '^--source=hdd/backups/192.168.28.99/hdd/lab --target= .* --no-copy --install --yes$' "$NR/zb.log")"
if [ "$NRRC" -eq 0 ] && [ -n "$NRSI" ] \
   && printf '%s' "$NRSI" | grep -qF -- ' --name=migawki-hdd-backups-192.168.28.99-hdd-lab ' \
   && printf '%s' "$NRSI" | grep -qF -- ' --recursive=flat ' \
   && ! grep -qF 'Dokąd' "$NR/wt.log" && ! grep -qF 'Ustawienia dodatkowe' "$NR/wt.log" \
   && grep -qF 'Co kopiować z' "$NR/tree.log" && grep -qF 'Jak długo trzymać migawki?' "$NR/wt.log" \
   && grep -qF 'Podsumowanie' "$NR/wt.log" && grep -qF 'MIGAWKI LOKALNE' "$NR/wt.log"; then
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
0${T}192.168.28.99
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
0${T}
" NR_TREE="$NRTK")
if has "$NROUT" " --name=192.168.28.99 " && ! grep -q '^delete-relation' "$NR/zb.log" && ! grep -qF "USUNIĘTA relacja" "$NR/wt.log"; then
    ok "new-relation: nazwa relacji 'removed' jest wolna -- kreator jej uzywa bez pytania i bez delete-relation (add-client archiwizuje stary rekord)"
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
if has "$DROUT" "ZATRZYMANE" && has "$DROUT" "Rekord relacji 'nazwa' ZOSTAŁ" && has "$DROUT" "uruchom to samo jeszcze raz" \
   && ! has "$DROUT" "USUNIĘTA Z POZOSTAŁOŚCIAMI" && ! has "$DROUT" "GOTOWE"; then
    ok "okno usuwania: gdy polowa zrodla nie wyszla i czasownik ZATRZYMAL sie przed purge (REV-144), okno mowi 'ZATRZYMANE, rekord ZOSTAL, uruchom to samo jeszcze raz' -- a nie 'usunieta z pozostalosciami'"
else
    bad "okno usuwania: komunikat po zatrzymaniu" "$DROUT" "$(cat "$DRD/err")"
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
   && has "$DROUT" 'Na 10.0.0.9 zostało konto relacji'; then
    ok "okno usuwania: bez roota do zrodla -- bez pozycji 'Posprzątaj na źródle', z poleceniem do recznego sprzatania, usuniecie z --keep-source i przypomnienie na koncu (U16)"
else
    bad "okno usuwania: brak roota do zrodla" "cl: $(printf '%s' "$DRCL" | cut -c1-300)" "argv: $(cat "$DRD/argv" 2>/dev/null)" "$DROUT"
fi

# 3k. F10 USTAWIENIA (wlasciciel 2026-10-19): lista kluczy z `settings --tsv` w sekcjach,
#     zmiana jednej wartosci, "Zapisz" = plan czasownika i WYKONAJ -> `settings set K=V --yes`.
cat > "$NR/bin/zb-set" <<'EOF'
#!/bin/bash
[ "$1" = settings ] || exit 9
case "$2" in
    --tsv) printf 'gui.language\ten\tdomyślne\tenum:en,pl\tjęzyk okien GUI\n'
           printf 'alerts.email\troot\tzfs-alert.conf\temail\tkto dostaje maile\n'
           printf 'alerts.digest_time\t07:00\tdomyślne\ttime\to której wychodzi dzienny mail\n'; exit 0 ;;
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
   && has "$SOUT" 'GOTOWE'; then
    ok "F10 okno ustawien: sekcje i zrodla wartosci z czasownika, zmiana jednej pozycji, Zapisz = plan i WYKONAJ (settings set K=V --yes)"
else
    bad "F10 okno ustawien" "menu: $(printf '%s' "$SMENU" | cut -c1-300)" "argv: $(cat "$SD/argv" 2>/dev/null)" "$SOUT" "$(cut -c1-200 "$SD/err")"
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
   && ! has "$NRL" 'Bez zmian' && ! has "$NRL" 'DALEJ --' && has "$NRL" 'SPACJA przełącza'; then
    ok "new-relation: 'Ustawienia dodatkowe' to CHECKLISTA z przyciskami Dalej/Wstecz -- zadna pozycja listy nie udaje przycisku 'dalej' (wlasciciel, 2026-09-20)"
else
    bad "new-relation: ksztalt kroku 9" "$(printf '%s' "$NRL" | cut -c1-400)"
fi
# ...i to samo dla KAZDEGO okna z lista w kreatorze: przycisk zatwierdzenia nazywa
# sie "Dalej" (albo nazywa AKCJE, jak "Usun zaznaczone"), nigdy "Wybierz" -- bo
# lista JEST odpowiedzia i Enter na pozycji ma isc dalej.
if [ "$(grep -c -- '--ok-button "Wybierz"' "$REPO/tui/new-relation.sh")" -eq 0 ] \
   && [ "$(grep -c -- '--ok-button "Dalej"' "$REPO/tui/new-relation.sh")" -ge 6 ]; then
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
0${T}
" NR_TREE="$NRTK"); NRRC=$?
if [ "$NRRC" -eq 1 ] && has "$NROUT" "ZATRZYMANE ZGODNIE Z WYBOREM" && has "$NROUT" "deploy.sh --commit-scope=pve10" && ! has "$NROUT" "NIE UDAŁO SIĘ" \
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
if has "$NRPLAN" 'Po WYKONAJ uruchomi się DOKŁADNIE' && has "$NRPLAN" '--exclude-family=__replicate_,__migration__,_tmp' \
   && has "$NRPLAN" 'Pomijane migawki z prefiksami: __replicate_, __migration__, _tmp.' \
   && printf '%s' "$NRPLAN" | grep -q '^Konto: ' && ! has "$NRPLAN" 'grant-remotely is noted'; then
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
if ! bash "$REPO/zfs-backup.sh" new-relation --source=x >/dev/null 2>"$NR/err" && grep -qF 'nie przyjmuje argumentow' "$NR/err"; then
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
            *" --plan "*) echo "co sie zmieni w crontabie:"; echo "  +0 22 * * 5 /x/zfs-job.sh \"h replica copy ($2)\" -- ..."; exit 0 ;;
            *) echo ">>> atrapa: zainstalowano"; exit 0 ;;
        esac ;;
    install-media-trigger) echo ">>> atrapa: regula"; exit 0 ;;
    remove-media-trigger) echo ">>> atrapa: regula zdjeta"; exit 0 ;;
    prepare-media) case " $* " in
            *" --list "*) printf '/dev/disk/by-id/usb-C	2G	QEMU	USB-C	-
' ;;
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
   && grep -F '4/6 rodzaj' "$RP/wt.log" | grep -q . && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'repl  dysk w slocie' \
   && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF -- '--default-item ~ repl ~' \
   && ! grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'Wpisz nazwę puli' \
   && grep -F '6/6 kiedy' "$RP/wt.log" | grep -qF '0 22 * * 5 ~ co tydzień, piątek 22:00' \
   && grep -F 'także po włożeniu' "$RP/wt.log" | grep -qF 'Uruchamiać kopię także po włożeniu dysku' \
   && grep -qF 'reguła udev ZOSTANIE ZAŁOŻONA' "$RP/wt.log" && grep -qF 'po ID puli: 4242' "$RP/wt.log" \
   && printf '%s' "$RPOUT" | grep -qF 'Pierwsza kopia ruszy po włożeniu dysku albo o czasie z harmonogramu.'; then
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
   && ! grep -qF 'także po włożeniu' "$RP/wt.log" && grep -q '^install-media-trigger --install$' "$RP/zb.log" \
   && printf '%s' "$RPOUT" | grep -qF 'Pierwsza kopia ruszy po włożeniu dysku.'; then
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
if [ "$RPRC" -eq 0 ] && grep -qF 'także po włożeniu' "$RP/wt.log" && ! grep -q '^install-media-trigger' "$RP/zb.log" \
   && grep -q -- '--on-insert=no --install --yes$' "$RP/zb.log" && grep -qF 'Po włożeniu: nic -- kopia tylko wg harmonogramu' "$RP/wt.log" \
   && grep -qF 'ZOSTANIE ZDJĘTA' "$RP/wt.log" && grep -q '^remove-media-trigger --install$' "$RP/zb.log"; then
    ok "replica: okno B zawsze (ustawienie repliki, nie hosta) -- Nie = --on-insert=no; zadna replika nie rusza po wlozeniu -> plan zdejmuje regule"
else
    bad "replica: kreator, B przy istniejacej regule" "rc=$RPRC" "$RPOUT" "$(cat "$RP/zb.log")" "$(tail -4 "$RP/wt.log" | cut -c1-300)"
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
   && ! grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'Sformatuj nowy nośnik' && grep -F '5/6 nośnik' "$RP/wt.log" | grep -qF 'Dodaj dysk (włożony zostanie sformatowany)'; then
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
RP9="$(grep -F '5/6 nośnik' "$RP/wt.log" | head -1)"
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
RP10="$(grep -F '5/6 nośnik' "$RP/wt.log" | head -1)"
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
if grep -q '^add-replica usb12 --source=hdd/data --dst=repl/replica --schedule=0 22 \* \* \* --removable --recursive=yes --exclude-child=^hdd/data/mail\$ .*--keep=6 --media-guid=4242 --on-insert=no --install --yes$' "$RP/zb.log"    && ! grep -q -- '--history=' "$RP/zb.log" && has "$RP12" 'Historia' && has "$RP12" '(fabryczne)' && ! has "$RP12" 'Kompresja'    && ! has "$RPLAST" 'Historia ' && has "$RPLAST" '6 ostatnich zdjęć replica_' && grep -qF 'Historia:   tylko najnowsze zdjęcie replica_' "$RP/wt.log"; then
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
RP13="$(grep -F 'Zmień replikę usb13' "$RP/wt.log" | head -1)"
if grep -q '^add-replica usb13 --source=hdd/data --dst=repl/replica .*--media-guid=4242 --on-insert=yes --install --yes$' "$RP/zb.log" \
   && grep -q '^install-media-trigger --install$' "$RP/zb.log" \
   && has "$RP13" '[ ] Po włożeniu dysku' && has "$RP13" 'Kiedy:      codziennie 22:00' && has "$RP13" 'Nośnik:     repl/replica (wymienny)' \
   && ! grep -qF '6/6 kiedy' "$RP/wt.log" && ! grep -qF '4/6 rodzaj' "$RP/wt.log"; then
    ok "replica: U8 -- lista z obecnymi wartościami; '[ ] Po włożeniu' przełącza od razu, Zapisz = --on-insert=yes + reguła, bez innych kroków"
else
    bad "replica: U8 lista zmiany" "$RPOUT" "$(cat "$RP/zb.log")" "$(printf '%s' "$RP13" | cut -c1-400)"
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
   && printf '%s' "$TRS" | grep -q 'MSG: hdd: tu nic do wybrania' && ! printf '%s' "$TRS" | grep -q '\[x\]\|\[ \]'; then
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
# c) Enter bez zadnego miejsca odmawia (zostaje w oknie); bez Enter/Esc koniec to Wstecz (rc 1)
TRC=$(trun "$TRD/a.json" 'space,enter'); TRCRC=$?
if [ "$TRCRC" -eq 1 ] && [ "$(tjq "$TRD/out.json" action)" = '"back"' ] && has "$TRC" 'MSG: Zaznacz co najmniej jedno miejsce (Spacja).'; then
    ok "tree: zdjecie jedynego miejsca i Enter = odmowa 'Zaznacz co najmniej jedno miejsce', wynik action=back, rc=1"
else
    bad "tree: Enter bez miejsca" "rc=$TRCRC" "$TRC" "$(cat "$TRD/out.json" 2>/dev/null)"
fi
# d) no_exc (Zmien relacje: add-source bierze cale miejsce): wyjatku nie ma, a miejsce nad celem kopii odmowa
TRD1=$(trun "$TRD/noexc.json" 'right,down,space')
TRD2=$(trun "$TRD/noexc.json" 'up,space')
if has "$TRD1" 'MSG: Tu wybiera się całe miejsca' && has "$TRD2" 'MSG: Pod hdd leży cel kopii (hdd/backups). Zaznacz węższe miejsce.'; then
    ok "tree: no_exc -- Spacja na dziecku miejsca odmawia ('Tu wybiera się całe miejsca'), miejsce nad celem kopii tez ('Zaznacz węższe miejsce')"
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
if [ "$TPRC" -ne 0 ] && ! grep -q '^save-profile' "$TP/zb.log" && printf '%s' "$GRIDSCR" | grep -qF 'Tego szczebla nie da się' \
   && printf '%s' "$GRIDSCR" | grep -E '^│ +Tego szczebla' | grep -q '│$' && ! printf '%s' "$GRIDSCR" | grep -qE '^Tego szczebla'; then
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
   && grep -F 'Usunięcie szablonu moj' "$TP/wt.log" | grep -qF -- '--defaultno' && grep -qF 'nie będzie miało z czego odświeżyć' "$TP/wt.log"; then
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
0${T}inna
0${T}adv
0${T}acct
0${T}root
0${T}extra
0${T}grant
0${T}__done__
1${T}
0${T}create
0${T}
0${T}
" NR_TREE='goto:hdd/data,space,enter'); NRRC=$?
if [ "$NRRC" -eq 0 ] && grep -q '^save-profile --from=relacja-pve9b --as=relacja-inna --hidden --force' "$NR/zb.log" \
   && grep -q '^delete-profile relacja-pve9b --yes' "$NR/zb.log" && has "$NROUT" "--profile=relacja-inna "; then
    ok "new-relation: Recznie + inna nazwa w kroku 7 -- szkic przeniesiony na relacja-<nowa nazwa>, stary usuniety"
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
    edit-relation)  case " $* " in *" --yes "*) echo ">>> atrapa: zmieniono" ;; *) echo "Edycja relacji: r1 (atrapa)"; echo
                        # X6: ER_HAND = config zmieniony recznie (minuta 29), plan wpisze 31.
                        [ -n "${ER_HAND:-}" ] && printf -- '--- proponowany config: /etc/x.conf ---\n  [template:profile__relacja-r1__daily]\n  -\tprune_schedule = 29 1 * * *\n  +\tprune_schedule = 31 1 * * *\n\n' || : ;;
                    esac ;;
    list-datasets)  echo '{"datasets":[{"name":"hdd"},{"name":"hdd/data"},{"name":"hdd/data/mail"},{"name":"hdd/iso"},{"name":"hdd/vm"}]}' ;;
    add-source|remove-source)
                    # X21: hdd/vm "lezy w celu" -- plan (bez --yes) odmawia, jak prawdziwy czasownik.
                    if [ "$3" = hdd/vm ]; then echo "FATAL: add-source: target 'hdd/backups' overlaps 'hdd/vm' (atrapa)"; exit 1; fi
                    echo ">>> atrapa: $1 $2 $3" ;;
    show-config)    echo '{"sections":[{"kind":"dataset","name":"hdd/backups/192.168.28.99/hdd/data","fields":{"pair_label":"r1","compression":"none"'"${ER_RAW:+,\"raw\":\"yes\"}"'}}]}' ;;
    set-transfer)   case " $* " in *" --yes "*) echo ">>> atrapa: set-transfer" ;; *) echo "Relacja 'r1': history=newest (sekcji: 1)"; echo "plan only -- nothing installed (add --yes to install)" ;; esac ;;
    show-tiers)     echo '{"name":"r1","mode":"remote","config":"/x.conf","target":[{"name":"hourly","mechanism":"flat","pattern":"automated_hourly","prefix":"automated_hourly_","keep":"24","retain":"","gfs":"","quiesce":"","send_schedule":"1 * * * *","prune_schedule":"21 * * * *","monitor_warn":"","monitor_crit":""},{"name":"daily","mechanism":"flat","pattern":"automated_daily","prefix":"automated_daily_","keep":"7","retain":"","gfs":"","quiesce":"auto,degrade","send_schedule":"11 1 * * *","prune_schedule":"31 1 * * *","monitor_warn":"","monitor_crit":""}],"source":[{"name":"hourly","mechanism":"flat","pattern":"automated_hourly","keep":"24","retain":""},{"name":"daily","mechanism":"flat","pattern":"automated_daily","keep":"7","retain":""}]}' ;;
    set-tiers)      case " $* " in *" --yes "*) echo ">>> atrapa: set-tiers" ;; *) echo "Relacja 'r1' -- szczeble:"; echo "  hourly: keep=12 (source)"; echo "plan only -- nothing installed (add --yes to install)" ;; esac ;;
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
EROUT=$(ER_TREE='goto:hdd/iso,space,goto:hdd/data,space,enter' er_run "0${T}dane
0${T}wykonaj
0${T}
"); ERRC=$?
ERB="$(cat "$ER/tree.log" 2>/dev/null)"
if [ "$ERRC" -eq 0 ] && grep -qx 'add-source r1 hdd/iso --yes' "$ER/zb.log" && grep -qx 'remove-source r1 hdd/data --yes' "$ER/zb.log" \
   && grep -qF 'DOJDĄ' "$ER/wt.log" && grep -qF 'ODPADNĄ' "$ER/wt.log" && has "$ERB" 'Co kopiować z' && has "$ERB" '[ ] data' && has "$ERB" '[x] iso' \
   && ! has "$ERB" 'Wyjątki' && ! has "$ERB" 'Sposób'; then
    ok "edit-relation: Datasety -- koszyk z obecnymi datasetami, kilka zmian, jeden plan DOJDA/ODPADNA, add-source + remove-source --yes; bez Sposob/Wyjatki"
else
    bad "edit-relation: Datasety (W4)" "rc=$ERRC" "$(cat "$ER/zb.log")" "$(grep -E 'Co kopiować|DOJD|ODPAD' "$ER/wt.log" | cut -c1-250)" "$(tail -3 "$ER/err")"
fi
# X21 (wlasciciel 2026-10-14): zmiana datasetow sprawdzona PRZED WYKONAJ -- odmowa czasownika
# (plan bez --yes) pokazana od razu, zadnego --yes, powrot do listy.
# X12: drzewo woli sie dwa razy (po odmowie wraca lista); druga linia ER_TREE brak = Esc.
EROUT=$(ER_TREE='goto:hdd/vm,space,enter' er_run "0${T}dane
0${T}
"); ERRC=$?
if grep -qx 'add-source r1 hdd/vm' "$ER/zb.log" && ! grep -q -- '--yes' <(grep -E '^(add|remove)-source' "$ER/zb.log")    && grep -qF 'Tej zmiany nie da się zrobić' "$ER/wt.log" && grep -qF "overlaps 'hdd/vm'" "$ER/wt.log" && ! grep -qF 'DOJDĄ' "$ER/wt.log"; then
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
ERM=$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | sed -n 3p)
if [ "$ERRC" -eq 0 ] && [ "$(grep -E -e '--yes$' "$ER/zb.log" | tr '\n' '|')" = 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes|set-transfer r1 --history=newest --yes|' ] \
   && has "$ERP" 'Adres źródła: 10.99.0.9' && has "$ERP" 'Ustawienia silnika:' && has "$ERM" 'Zapisz zmiany (2)' \
   && hasE "$ERM" 'Źródło +192\.168\.28\.99 -> 10\.99\.0\.9 \[zmiana\]' && hasE "$ERM" 'Silnik +\[zmiana\]'; then
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
ERC1="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | head -1)"
if [ "$ERRC" -eq 0 ] && grep -qx 'activate r1 --host=10.99.0.9 --skip-final-catchup --yes' "$ER/zb.log" \
   && [ "$(grep -c '^activate' "$ER/zb.log")" -eq 1 ] && ! grep -qE '^(final-catchup|set-endpoint|verify-endpoint|activate-client)' "$ER/zb.log" \
   && has "$ERA" 'Zapisany: 192.168.28.99:22' && has "$ERA" '~ 192.168.28.99:22 ~' && has "$ERA" 'po przeniesieniu kolektora' \
   && hasE "$ERC1" 'Źródło +192\.168\.28\.99 ~'; then
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
   && grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | sed -n 2p | grep -qE 'Źródło +192\.168\.28\.99 -> 10\.99\.0\.9 \[zmiana\]'; then
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
   && ! grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | grep -qF '192.168.28.250 [zmiana]'; then
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
if grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF 'Ręczna edycja konfigu' \
   && ! grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF 'Źródło' \
   && ! grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qF ' ~ adres ~ '; then
    ok "edit-relation: relacja lokalna -- karta bez wiersza Źródło (adres)"
else
    bad "edit-relation: relacja lokalna bez Adres hosta" "$(grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | cut -c1-400)"
fi
# U25: wiersze STALE karty (rodzaj, cel, nazwa, konto, dodatkowe) maja dopisek "(stałe)"; Enter na
# nich otwiera msgbox "<Pole> -- stałe" (nowa relacja), nic nie zmienia i wraca na karte.
EROUT=$(er_run "0${T}cel
0${T}
1${T}
"); ERRC=$?
ERC1="$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | head -1)"
ERMB="$(grep -F 'Cel -- stałe' "$ER/wt.log" | grep -F -e '--msgbox' | head -1)"
if [ "$ERRC" -eq 1 ] && hasE "$ERC1" 'Rodzaj +backup +\(stałe\)' && hasE "$ERC1" 'Nazwa +r1 +\(stałe\)' && hasE "$ERC1" 'Konto +root +\(stałe\)' \
   && has "$ERMB" 'nowa relacja' && ! grep -qE '^(add-source|remove-source|set-tiers|edit-relation|activate|set-transfer|save-profile|delete-profile)' "$ER/zb.log"; then
    ok "edit-relation: karta -- Rodzaj/Nazwa/Konto z dopiskiem (stałe); Enter na Cel = msgbox 'Cel -- stałe' (nowa relacja), zaden czasownik zmieniajacy nie wolany"
else
    bad "edit-relation: karta, wiersze stale" "rc=$ERRC" "$(printf '%s' "$ERC1" | cut -c1-500)" "$(printf '%s' "$ERMB" | cut -c1-300)" "$(cat "$ER/zb.log")"
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
# U36 (wlasciciel 2026-10-20: "to w sumie F7 na calej relacji"): akcja karty "Kopia teraz"
# = run-relation (jak F7 na F3); z czekajacymi zmianami najpierw odmawia (kopia idzie po
# zainstalowanym cronie).
EROUT=$(er_run "0${T}teraz
"); ERRC=$?
ERT1="$(cat "$ER/zb.log")"
EROUT=$(er_run "0${T}adres
0${T}10.99.0.9
0${T}teraz
0${T}
1${T}
0${T}
"); ERT2="$(cat "$ER/zb.log")"; ERW2="$(cat "$ER/wt.log")"
if printf '%s\n' "$ERT1" | grep -qx 'run-relation r1' && ! printf '%s\n' "$ERT2" | grep -q '^run-relation' \
   && has "$ERW2" 'Kopia teraz' && has "$ERW2" 'najpierw Zapisz zmiany'; then
    ok "edit-relation: karta 'Kopia teraz' = run-relation (jak F7); z czekajacymi zmianami najpierw odmawia"
else
    bad "edit-relation: karta Kopia teraz (U36)" "bez zmian: $ERT1" "ze zmiana: $ERT2"
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
   && grep -F 'Co zmienić?' "$ER/wt.log" | head -1 | grep -qE 'Datasety +1' && grep -qF 'Ręczna edycja konfigu' "$ER/wt.log"; then
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
ERT=$(grep -F -e '--menu' "$ER/wt.log" | grep -F 'Relacja r1 ~' | sed -n 2p)
if [ "$ERRC" -eq 1 ] && grep -qx 'set-tiers r1 --src-tier=hourly --keep=12 --plan' "$ER/zb.log" \
   && ! grep -q -- '--yes$' <(grep '^set-tiers' "$ER/zb.log") && ! grep -qE '^(save-profile|delete-profile)' "$ER/zb.log" \
   && hasE "$ERT" 'Retencja źródła *\[zmiana\]' && has "$ERT" 'Zapisz zmiany (1)'; then
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
EROUT=$(er_run "0${T}zapisz
0${T}r1-szablon
0${T}
1${T}
"); ERRC=$?
if grep -q '^save-profile --from=d7h24 --as=r1-szablon --description=Ustawienia relacji r1$' "$ER/zb.log" && ! grep -q -- '--hidden' "$ER/zb.log"; then
    ok "edit-relation: Zapisz ustawienia relacji jako szablon -- zwykly szablon (bez --hidden), widoczny na F5"
else
    bad "edit-relation: zapisz jako szablon" "rc=$ERRC" "$(cat "$ER/zb.log")"
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
   && has "$ERP" 'nie szablonem' && ! has "$ERP0" 'inne niż jej szablon'; then
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
  echo "  Config docelowy:  $(cygpath -m "$HE/c.conf" 2>/dev/null || echo "$HE/c.conf") (istnieje)"
  echo "--- kandydat CONFIG v4 (pelny: istniejace + nowy job) ---"
  printf '[template:profile__relacja-r1__lsrc_daily]\n\tprune_schedule = 31 1 * * *\n[dataset:hdd/ct]\n\tpair_label = r1\n'
  echo "--- wygenerowany blok crona ---"; } > "$HE/plan.txt"
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
# odpowiedzi (co / dokad / z kiedy / sprawdz). Atrapa czasownika (zb) zapisuje argv
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
        for d in usb9 usb9/backups usb9/backups/192.168.28.98 usb9/backups/192.168.28.98/hdd/data usb9/backups/192.168.28.98/hdd/data/docs hdd hdd/data hdd/foo/bar tank/b/hdd/data; do
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
      bash "$REPO/tui/restore.sh" k2 ) </dev/null >"$RW/out" 2>"$RW/err"
    RW_RC=$?
}
rw_ran() { cat "$RW/ran" 2>/dev/null; }

# 1. obok, tylko docs: config = ten, ktory MA wiersze (jobs.h.conf jest pierwszy w kolejnosci i pusty),
#    onto = baza/basename; bez --at (p0 = najnowszy), bez --yes. Okno podsumowania ma "Wymaga zgody" i --defaultno.
printf '0\tobok\n0\thdd/restore\n0\tp0\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
W1="restore ~ k2 ~ k2 ~ --source=tank/b/hdd/data/docs ~ --onto=hdd/restore/docs ~ --config=$RWCFG"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W1" ] && ! has "$(rw_ran)" '--at' && ! has "$(rw_ran)" '--yes'; then
    ok "restore: obok, tylko docs -> restore k2 k2 --source=docs --onto=hdd/restore/docs --config=<ten z wierszami>, bez --at i bez --yes"
else
    bad "restore: obok, tylko docs" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W1" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi
RWSUM="$(grep -F -A 30 'sprawdź' "$RW/wt.log" | head -40)"   # argv okna to jedna wielowierszowa pozycja dziennika
# U14: zgoda jest (atrapa: create rewind) -- podsumowanie mowi, jaka, i nie straszy brakiem.
if has "$RWSUM" 'Zgoda 10.0.0.9: create rewind' && has "$RWSUM" '--defaultno' && ! has "$RWSUM" 'Wymaga zgody' && ! grep -qF 'brak zgody' "$RW/wt.log"; then
    ok "restore: okno podsumowania ma domyslne 'Nie' (--defaultno) i mowi, jaka zgode wydal cel (U14)"
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
printf '0\tdalej\n0\tobok\n0\thdd/restore\n0\tp0\n0\t\n' > "$RW/answers"
STUB_GRANT_OUT='HOST=10.0.0.9\nLABEL=pve9\nGRANT=none' STUB_GRANT_RC=1 rw_run "$RW/t-docs.json"
RWSUM_N="$(grep -F -A 30 'sprawdź' "$RW/wt.log" | head -40)"
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
printf '0\tobok\n0\thdd/restore\n0\tp0\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
RWSUM_L="$(grep -F -A 30 'sprawdź' "$RW/wt.log" | head -40)"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W1" ] && has "$RWSUM_L" 'Relacja lokalna' && ! has "$RWSUM_L" 'Wymaga zgody'; then
    ok "restore: relacja lokalna obok -> to samo polecenie, podsumowanie bez zadania zgody"
else
    bad "restore: relacja lokalna obok" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W1" "sum: $(printf '%s' "$RWSUM_L" | grep -i -E 'zgod|lokaln' | cut -c1-200)"
fi
cp "$RW/plan.remote.json" "$RW/plan.json"

# 2. miejsce, cala relacja, punkt p1 (starszy): bez --source (WHOLE), bez --onto, z --at
printf '0\tmiejsce\n0\tp1\n0\t\n' > "$RW/answers"
rw_run "$RW/t-whole.json"
# --at dla punktu p1 = sekunda PRZED nowszym punktem p0 (P7, 2026-10-15): jeden bieg robi migawki
# datasetow sekundy po sobie, wiec sekunda migawki korzenia odcinala dzieci tego samego biegu.
RWAT="$(date -d @$((1792081503 - 1)) '+%Y-%m-%d %H:%M:%S')"
W2="restore ~ k2 ~ --at=$RWAT ~ --config=$RWCFG"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W2" ]; then
    ok "restore: na miejsce, cala relacja, punkt p1 -> restore k2 --at=<czas p1> --config=... (bez --source, bez --onto)"
else
    bad "restore: na miejsce, cala relacja" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W2" "err: $(cut -c1-200 "$RW/err")"
fi

# 3. miejsce z wylaczonym mail: nie cala relacja -> --source z lista (rodzice przed dziecmi)
printf '0\tmiejsce\n0\tp0\n0\t\n' > "$RW/answers"
rw_run "$RW/t-nomail.json"
W3="restore ~ k2 ~ --source=tank/b/hdd/data,tank/b/hdd/data/docs ~ --config=$RWCFG"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W3" ]; then
    ok "restore: na miejsce z wylaczonym mail -> --source=data,data/docs (WHOLE=0 dodaje --source)"
else
    bad "restore: na miejsce bez mail" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W3" "err: $(cut -c1-200 "$RW/err")"
fi

# 4. obok, cala relacja: --source i --onto w tej samej kolejnosci, onto = baza/data/...
printf '0\tobok\n0\thdd/restore\n0\tp0\n0\t\n' > "$RW/answers"
rw_run "$RW/t-whole.json"
W4="restore ~ k2 ~ k2 ~ --source=tank/b/hdd/data,tank/b/hdd/data/docs,tank/b/hdd/data/mail ~ --onto=hdd/restore/data,hdd/restore/data/docs,hdd/restore/data/mail ~ --config=$RWCFG"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$W4" ]; then
    ok "restore: obok, cala relacja -> --source=3 datasety, --onto=hdd/restore/data/... w tej samej kolejnosci"
else
    bad "restore: obok, cala relacja" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $W4" "err: $(cut -c1-200 "$RW/err")"
fi

# 5. Wstecz z podsumowania wraca do punktow i NIC nie uruchamia: summary rc 1, punkty znowu, summary rc 0 -> JEDNA linia ran
printf '0\tobok\n0\thdd/restore\n0\tp0\n1\t\n0\tp0\n0\t\n' > "$RW/answers"
rw_run "$RW/t-docs.json"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran | grep -c '')" -eq 1 ] && [ "$(grep -c 'sprawdź' "$RW/wt.log")" -eq 2 ]; then
    ok "restore: Wstecz z podsumowania nic nie uruchamia -- dwa razy okno 'sprawdz', JEDNO wywolanie czasownika"
else
    bad "restore: Wstecz z podsumowania" "rc=$RW_RC" "ran: $(rw_ran)" "sprawdz: $(grep -c 'sprawdź' "$RW/wt.log")"
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
# Jedno polecenie: restore --from-copy=.. --onto=.. [--at=..] [--with-history] [--overwrite];
# nigdy --yes ani --config. Atrapa zfs odpowiada na liste wszystkich datasetow hosta
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
      bash "$REPO/tui/restore.sh" "$@" ) </dev/null >"$RW/out" 2>"$RW/err"
    RW_RC=$?
}

# c1. hdd/data ISTNIEJE -> okno nadpisania ("JUŻ ISTNIEJĄ"); Nadpisz; p0; historia Nie -> --overwrite, bez --at/--with-history
printf '0\thdd/data\n0\t\n0\tp0\n1\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
C1="restore ~ --from-copy=$RWCP ~ --onto=hdd/data ~ --overwrite"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C1" ] && ! has "$(rw_ran)" '--yes' && ! has "$(rw_ran)" '--config' \
   && ! has "$(rw_ran)" '--at' && ! has "$(rw_ran)" '--with-history'; then
    ok "restore --from-copy: cel istnieje, Nadpisz, najnowszy, bez historii -> --from-copy=.. --onto=hdd/data --overwrite (bez --at/--with-history/--yes/--config)"
else
    bad "restore --from-copy: nadpisanie" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C1" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi
if grep -qF "\"roots\": [\"$RWCP\"]" "$RW/last-spec.json" 2>/dev/null && grep -qF '"no_exc": true' "$RW/last-spec.json" 2>/dev/null \
   && grep -qF 'JUŻ ISTNIEJĄ' "$RW/wt.log"; then
    ok "restore --from-copy: drzewo dostalo wstepnie zaznaczony korzen (DATASET), a okno nadpisania mowi 'JUŻ ISTNIEJĄ'"
else
    bad "restore --from-copy: spec drzewa / okno nadpisania" "spec: $(cut -c1-300 "$RW/last-spec.json" 2>/dev/null)" "wt: $(grep -c 'ISTNIEJ' "$RW/wt.log")"
fi

# c2. nowa nazwa (nie istnieje -> bez okna nadpisania); starszy punkt p1; historia Tak
printf '0\thdd/restore/data\n0\tp1\n0\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
C2="restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data ~ --at=$RWAT ~ --with-history"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C2" ] && ! has "$(rw_ran)" '--overwrite' && ! grep -qF 'ISTNIEJ' "$RW/wt.log"; then
    ok "restore --from-copy: nowy cel, punkt p1, historia Tak -> --onto=hdd/restore/data --at=<czas p1> --with-history, bez --overwrite i bez okna nadpisania"
else
    bad "restore --from-copy: nowy cel + historia" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C2" "err: $(cut -c1-200 "$RW/err")"
fi

# c3. korzen bez wzorca backups -> podpowiedz <pula>/restore/<ostatni czlon>
printf '0\thdd/restore/bar\n0\tp0\n1\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp-bar.json" --from-copy
C3="restore ~ --from-copy=hdd/foo/bar ~ --onto=hdd/restore/bar"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C3" ] && grep -qF -- 'hdd/restore/bar ~' "$RW/wt.log"; then
    ok "restore --from-copy: hdd/foo/bar (bez wzorca backups) -> pole 'dokad' podpowiada hdd/restore/bar, --onto=hdd/restore/bar"
else
    bad "restore --from-copy: podpowiedz dla hdd/foo/bar" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C3" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 8 "$RW/wt.log" | cut -c1-300)"
fi
# podpowiedz dla wzorca backups: hdd/data (z usb9/backups/<host>/hdd/data) -- widac w dzienniku c1/c2 jako domyslna wartosc pola
printf '0\thdd/restore/data\n0\tp0\n1\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
if grep -qF -- ' ~ hdd/data ~ ' "$RW/wt.log"; then      # argv okna jest wielowierszowy (tekst ma \n) -- domyslna wartosc to ostatni argument
    ok "restore --from-copy: usb9/backups/<host>/hdd/data -> podpowiedz 'hdd/data'"
else
    bad "restore --from-copy: podpowiedz dla wzorca backups" "$(tail -n 6 "$RW/wt.log" | cut -c1-300)"
fi

# c4. dwa korzenie -> dwa pola 'dokad', obie listy w kolejnosci drzewa
printf '0\thdd/restore/data\n0\thdd/restore/bar\n0\tp0\n1\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp-two.json" --from-copy
C4="restore ~ --from-copy=$RWCP,hdd/foo/bar ~ --onto=hdd/restore/data,hdd/restore/bar"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "$C4" ] && [ "$(grep -c -F inputbox "$RW/wt.log")" -eq 2 ]; then
    ok "restore --from-copy: dwa korzenie -> dwa pola 'dokad', --from-copy=A,B --onto=a,b w kolejnosci drzewa"
else
    bad "restore --from-copy: dwa korzenie" "rc=$RW_RC" "ran: $(rw_ran)" "chce: $C4" "err: $(cut -c1-200 "$RW/err")" "wt: $(tail -n 3 "$RW/wt.log" | cut -c1-200)"
fi

# c6 (P5, wlasciciel 10-15): cel BEZ puli ("restore/home" -- jeden Backspace za duzo) nie
# przechodzi do polecenia: okno "zla nazwa" i to samo pole jeszcze raz; potem poprawna nazwa.
printf '0\trestore/home\n0\t\n0\thdd/restore/data\n0\tp0\n1\t\n0\t\n' > "$RW/answers"
rw_copy "$RW/t-cp1.json" --from-copy "$RWCP"
if [ "$RW_RC" -eq 0 ] && [ "$(rw_ran)" = "restore ~ --from-copy=$RWCP ~ --onto=hdd/restore/data" ] \
   && grep -q 'zła nazwa' "$RW/wt.log" && ! grep -q 'onto=restore/home' "$RW/ran"; then
    ok "restore --from-copy: cel bez puli ('restore/home') -> okno 'zła nazwa' i to samo pole, polecenie dopiero z poprawna nazwa (P5)"
else
    bad "restore --from-copy: cel bez puli (P5)" "rc=$RW_RC ran=$(rw_ran)" "$(grep -c 'zła nazwa' "$RW/wt.log")"
fi
# P1: po biegu napis o Enterze jest NA EKRANIE (stdout), nie schowany w stderr.
if grep -q '=== GOTOWE (rc=0). Enter = powrót do GUI' "$RW/out"; then
    ok "restore: po biegu na ekranie '=== GOTOWE (rc=0). Enter = powrót do GUI' (P1)"
else
    bad "restore: napis Enter po biegu (P1)" "$(tail -3 "$RW/out")"
fi

# c5. bez argumentow: uzycie, exit 2
RWU="$( export NR_DIR="$RW" WHIPTAIL="$RW/bin/whiptail" PYTHON="$PY" PATH="$RW/bin:$PATH"; bash "$REPO/tui/restore.sh" </dev/null 2>&1 )"; RWURC=$?
if [ "$RWURC" -eq 2 ] && has "$RWU" 'użycie' && has "$RWU" '--from-copy'; then
    ok "restore.sh bez argumentow -> 'użycie: ... --from-copy', exit 2"
else
    bad "restore.sh bez argumentow" "rc=$RWURC" "out: $RWU"
fi
rm -rf "$RW"

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
eval "$(sed -n '/^pool_roots_to_children() {/,/^}/p' "$REPO/tui/replica.sh")"
if declare -F pool_roots_to_children >/dev/null; then
    T_NAME=(hdd hdd/a hdd/a/x hdd/b hdd/c hdd/c/y tank tank/z)
    B_ROOT=(hdd tank/z); B_EXCL=($'hdd/b\nhdd/c/y' "")
    pool_roots_to_children; u67_rc=$?
    u67_got="$(printf '%s;' "${SRC_ROOT[@]}")|$(printf '%s;' "${SRC_EXCL[@]}" | tr '\n' ',')"
    # H-1: the basket itself keeps the pool as chosen (Wstecz shows it ticked, not "[-]")
    [ "${B_ROOT[0]}" = hdd ] || u67_got="$u67_got (basket changed: ${B_ROOT[*]})"
    if [ "$u67_rc" -eq 0 ] && [ "$u67_got" = "hdd/a;hdd/c;tank/z;|;hdd/c/y;;" ] && printf '%b' "$POOL_NOTE" | grep -q 'Cała pula hdd = 2 datasetów'; then
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
