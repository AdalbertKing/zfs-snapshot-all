#!/bin/bash
# ============================================================================
# tui -- PIEC OKIEN, SPRAWDZONE BEZ TERMINALA
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
if hasE "$S200" '^║ lab-ct201 +pve10<192.168.28.99 +backup +active +aktualne +6.1M +[0-9]{2}:30 +║'; then
    ok "relacje: jeden wiersz na RELACJE -- nazwa, KIERUNEK (ten host po lewej), TYP, stan z rekordu, kopie z monitora, GB calej relacji, nastepny bieg (200 kolumn; wlasciciel 2026-09-12: typ i GB w liscie)"
else
    bad "relacje: wiersz relacji sklejony z czterech czytelnikow" "$S200"
fi
if hasE "$S" '^║ lab-ct201 +pve10<192.168.28.99 +active +║│' && hasE "$S" '^║ Relacja +Kierunek +Stan +║│' && hasE "$S120" '^║ lab-ct201 +pve10<192.168.28.99 +backup +active +aktualne +║│'; then
    ok "relacje: przy 80 lista ma trzy kolumny (Relacja, Kierunek, Stan), przy 120 dochodza Typ i Kopie -- panel stoi obok od 80"
else
    bad "relacje: kolumny listy rosna z szerokoscia" "$S" "$S120"
fi
if hasE "$S120" 'Ostatni +brak zapisu w historii'; then
    ok "relacje: ostatni wynik zszedl do panelu (kolumne zajal kierunek)"
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
if has "$S" 'Relacje na kolektorze pve10 (5)'; then
    ok "relacje: tytul ramki liczy relacje ZYWE (5), bez rekordu usunietego"
else
    bad "relacje: licznik relacji" "$S"
fi
# Relacja w zasiewie: zamiast godziny -- NASTEPNY KROK slowami CLI.
if hasE "$S200" '^║ duplikat +pve10[?]192.168.28.99 +backup +seeding +-- +- +seed duplikat +║' && hasE "$S120" 'Następny +seed duplikat'; then
    ok "relacje: relacja nieaktywna pokazuje NASTEPNY KROK CLI (seed duplikat), nie godzine z crona -- w kolumnie (200) i w panelu (120)"
else
    bad "relacje: nastepny krok dla relacji w zasiewie" "$S200" "$S120"
fi
# Rekord usuniety jest faktem, ale nie robota: jest, i jest OSTATNI.
if [ "$(printf '%s\n' "$S" | grep -n '192.168.28.99 *removed' | cut -d: -f1)" -gt "$(printf '%s\n' "$S" | grep -n '^║ lab-vm101' | cut -d: -f1)" ] 2>/dev/null; then
    ok "relacje: rekord 'removed' jest widoczny i stoi na koncu listy"
else
    bad "relacje: rekord removed" "$S"
fi
# Panel OBOK listy (prawy): pierwszy wiersz (duplikat) ma focus; zrodla i cel
# NIE sa w panelu -- sa w dolnym panelu par (wlasciciel 2026-09-11).
if has "$S" 'duplikat -- szczegóły' && ! has "$S" 'Źródła' && ! hasE "$S" '│ Cel ' && has "$S200" "brak zapisu w historii (nie wiadomo, nie 'OK')"; then
    ok "relacje: prawy panel mowi o wierszu z focusem i tlumaczy brak historii; zrodel i celu w nim NIE ma"
else
    bad "relacje: panel szczegolow" "$S" "$S200"
fi
if has "$S" 'Datasety relacji duplikat: 1 para, wg rekordu, nie crona' && has "$S" '192.168.28.99:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "relacje: dolny panel -- relacja BEZ crona (seeding) ma pare policzona z rekordu i tytul to MOWI"
else
    bad "relacje: pary z rekordu" "$S"
fi
S4="$(screen relacje down,down,down,down --width 200 --height 40)"
if has "$S4" 'lab-vm101 -- szczegóły' && hasE "$S4" 'Następny   2026-09-09 [0-9]{2}:24:00   \(wg crontaba\)' && has "$S4" 'Wysyłka    24 * * * *   rodzina automated_hourly'; then
    ok "relacje: kursor przesuwa panel; nastepny bieg policzony z harmonogramu, wysylka nazywa harmonogram i rodzine"
else
    bad "relacje: kursor i nastepny bieg" "$S4"
fi
if has "$S4" 'Kopie      aktualne   progi 90m / 150m'; then
    ok "relacje: panel nazywa progi monitora przy werdykcie"
else
    bad "relacje: progi w panelu" "$S4"
fi
if has "$S4" 'Porządki   44 * * * *   trzyma -H24 -D7 -W4 -M12   drabina GFS' && has "$S4" 'U źródła   3 * * * *   trzyma -H24 -D7 -W4 -M12   drabina GFS'; then
    ok "relacje: panel -- porzadki i porzadki u ZRODLA w OSOBNYCH wierszach: harmonogram, retencja, drabina GFS (z list-jobs, bez show-config)"
else
    bad "relacje: porzadki w panelu" "$S4"
fi
if hasE "$S4" 'Biegi 7d +[0-9]+ ' && hasE "$S4" 'Czas o/ś/m [0-9/]+s ' && hasE "$S4" 'Wolumen +[0-9.]+[KMG] ' && has "$S4" 'Datasety   1 para   lądowisk 1' && has "$S4" 'Utworzona  2026-09-08' && has "$S4" 'Zasiew     2026-09-08' && has "$S4" 'Aktywowana 2026-09-08'; then
    ok "relacje: panel jako TABELA -- jeden fakt w wierszu: biegi, czas o/s/m, wolumen, datasety, utworzona/zasiew/aktywowana (wlasciciel 2026-09-12: kolumny i wiersze)"
else
    bad "relacje: statystyka/historia w panelu" "$S4"
fi
# DOLNY PANEL Z CRONA: para w jednej linii, gdy sie miesci (200); inaczej
# zrodlo i pod nim cel (80, 120). Od 100 kolumn kopie, czas i GB per para --
# te same liczby co F2 -- przy ostatniej linii pary.
if has "$S4" 'Datasety relacji lab-vm101: 1 para, wg crona   [źródło → cel | Kopie | Szczeble | Czas o/ś/m | GB]' \
        && hasE "$S4" '^║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101 +aktualne +[0-9/]+s +[0-9.]+[KMG] +║'; then
    ok "relacje: dolny panel przy 200 -- para w jednej linii z kopiami, czasem o/s/m i GB"
else
    bad "relacje: pary przy 200" "$S4"
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
if has "$S4_120" '║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 ' && hasE "$S4_120" '^║   → hdd/backups/192.168.28.99/hdd/lab/vm-101 +aktualne +[0-9/]+s +[0-9.]+[KMG] +║'; then
    ok "relacje: przy 120 para, ktora sie nie miesci, to zrodlo i pod nim cel z liczbami -- nic nie uciete"
else
    bad "relacje: pary przy 120" "$S4_120"
fi
S4_80="$(screen relacje down,down,down,down)"
if has "$S4_80" '║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 ' && has "$S4_80" '║   → hdd/backups/192.168.28.99/hdd/lab/vm-101 ' && ! has "$S4_80" 'aktualne      4/3/4s'; then
    ok "relacje: ...a przy 80 to samo bez liczb"
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
# TAB: kursor na pary; Enter na parze skacze do TEGO zadania na F2.
TP="$(screen relacje down,tab)"
if has "$TP" 'Enter = to zadanie na F2   Tab wraca do relacji'; then
    ok "relacje: Tab przenosi kursor na pary (stopka mowi, co robi Enter)"
else
    bad "relacje: Tab" "$TP"
fi
TE="$(screen relacje down,tab,enter)"
if has "$TE" '[F2 Zadania]' && has "$TE" 'źródło      zfsbackup-pve10@192.168.28.99:hdd/lab/ct-201' && has "$TE" 'wysyłka hourly'; then
    ok "relacje: Enter na parze = F2 z kursorem na zadaniu wysylki tej pary"
else
    bad "relacje: Enter na parze" "$TE"
fi
TR="$(screen relacje tab,enter)"
if has "$TR" '[F3 Relacje]' && has "$TR" 'ta para jest z rekordu, nie z crona'; then
    ok "relacje: Enter na parze z REKORDU mowi, ze zadania na F2 nie ma"
else
    bad "relacje: Enter na parze z rekordu" "$TR"
fi

# --- PAUZA: prawdziwy stan z pause-client na pve10 -------------------------
SP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down --width 200 2>&1)"
if hasE "$SP" '^║ lab-srv-b +pve10<192.168.28.99 +backup +active PAUZA +aktualne +0B +-- pauza -- +║'; then
    ok "relacje: relacja wstrzymana ma PAUZA w stanie i '-- pauza --' zamiast nastepnego biegu"
else
    bad "relacje: wiersz pauzy" "$SP"
fi
if has "$SP" 'Uwaga      relacja wstrzymana (pause-client)'; then
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
if has "$E" "To NIE znaczy 'host nic nie robi'"; then
    ok "relacje: pusty host tlumaczy sie (brak rekordu i bloku, nie brak backupow)"
else
    bad "relacje: pusty host" "$E"
fi

# ============================================================================
# EKRAN F2: ZADANIA -- co chodzi w cronie, z relacja i KIERUNKIEM
# ============================================================================
# Wlasciciel, 2026-09-09: "obok kolumny relacja wstaw kolumne z kierunkiem np.
# pve9>pve10, lub pve9<>pve10, lub local" -- lewa strona to ZAWSZE ten host.
Z="$(screen zadania)"
if has "$Z" '╔═ Zadania na pve10 (32 zadania, 4 relacje) ═'; then
    ok "zadania: F2 liczy zadania z crona i relacje, ktore je maja"
else
    bad "zadania: tytul" "$Z"
fi
if hasE "$Z" '^║ lab-vm101 +pve10<192.168.28.99 +wysyłka hourly +[0-9-]+/[0-9-]+/[0-9-]+s +[0-9.]+[KMG] +aktualne +║' && ! has "$Z" 'Zakres'; then
    ok "zadania: wysylka pobrania = 'pve10<peer' (ten host po lewej), rodzina bez automated_, CZASY i GB jak w mailu, werdykt slowem -- i ZADNEJ kolumny Zakres"
else
    bad "zadania: wiersz wysylki" "$Z"
fi
if hasE "$Z" '^║ lab-vm101 +local +porządki -H24 +[0-9]+/[0-9]+/[0-9]+s +- +aktualne'; then
    ok "zadania: porzadki na ladowisku = 'local', to, co trzymaja (-H24), czasy z ich linii crona, GB '-' (porzadki nic nie pisza)"
else
    bad "zadania: wiersz porzadkow" "$Z"
fi
if [ "$(printf '%s\n' "$Z" | grep -cE '^║ lab-vm101 +pve10<192.168.28.99 +porządki -H24 ')" -eq 1 ] && [ "$(printf '%s\n' "$Z" | grep -cE '^║ lab-vm101 +local +porządki -H24 ')" -eq 1 ]; then
    ok "zadania: porzadki na ZDALNYM zrodle niosa kierunek relacji, nie 'local'"
else
    bad "zadania: zdalne porzadki" "$Z"
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
print("%d/%d/%ds" % (row["last_s"], row["avg_s"], row["max_s"]), h(vol), row["runs"], row["last_at"])
PYEOF
)
set -- $want
if has "$Z" " $1 " && has "$Z" " $2 "; then
    ok "zadania: czasy ($1) i GB ($2) w wierszu wysylki sa DOKLADNIE tym, co job-stats mowi o jej linii crona i jej ladowisku"
else
    bad "zadania: czasy/GB z job-stats" "want: $want" "$Z"
fi
if has "$Z" "biegi       $3 w oknie 7 dni" && has "$Z" "ostatni $4 $5 rc=0" && has "$Z" 'czas        ostatni ' && has "$Z" '(jak w mailu)' && has "$Z" 'wolumen     '"$2"' zapisane w migawkach automated_hourly w oknie 7 dni'; then
    ok "zadania: panel nazywa biegi, ostatni czas/rc, czas ostatni/sredni/maks i wolumen z oknem digestu"
else
    bad "zadania: panel czasow" "$Z"
fi
# bez zrodla: '?' w kolumnach i zdanie w panelu, nie zera
ZS="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --status "$P10/status.json" --jobs "$P10/list-jobs.json" --monitors "$P10/monitor.json" --stats "$FIX/nie-ma.json" --screen zadania 2>&1)"
if hasE "$ZS" '^║ lab-vm101 +pve10<192.168.28.99 +wysyłka hourly +[?] +[?] +aktualne' && has "$ZS" 'job-stats --json nie odpowiedział' && has "$ZS" '! bez odpowiedzi: 1'; then
    ok "zadania: zepsute job-stats -> '?' w komorkach i zdanie w panelu, nigdy zero udajace pomiar"
else
    bad "zadania: zepsute job-stats" "$ZS"
fi
ZH3="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --stats "$P10/job-stats.json" --screen zadania 2>&1)"
if hasE "$ZH3" '^║ pve9 +hostA>pve9 +wysyłka hourly +- +- +spóźnione' && has "$ZH3" 'brak biegów tego zadania w dzienniku w oknie 7 dni'; then
    ok "zadania: zadanie, ktorego nie ma w dzienniku, pokazuje '-' i mowi to w panelu (a wysylka do peera nie ma wolumenu do zmierzenia tutaj)"
else
    bad "zadania: brak biegow" "$ZH3"
fi
Z100="$(screen zadania "" --width 100)"
if has "$Z100" 'Harmonogram' && ! has "$Z" 'Harmonogram' && has "$Z" 'harmonogram 24 * * * *'; then
    ok "zadania: przy 80 harmonogram zostaje w panelu (miejsce maja czasy), od 100 wraca jako kolumna"
else
    bad "zadania: harmonogram 80/100" "$Z" "$Z100"
fi

# ZRODLO I CEL W PANELU, W CALOSCI. Wlasciciel, 2026-09-11: "Zmieniamy nazwe
# Zakres na Cel i dodajemy tez Zrodlo". Dla pobrania zrodlo jest zdalne, cel
# to ladowisko tutaj; kierunek mowi, ktore jest ktorym.
if has "$Z" 'źródło      zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' && has "$Z" 'cel         hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "zadania: panel pobrania -- ZRODLO zdalne i CEL lokalny, pelne sciezki, nic nie uciete"
else
    bad "zadania: zrodlo/cel w panelu" "$Z"
fi
ZP="$(screen zadania down)"
if has "$ZP" 'źródło      -' && has "$ZP" 'cel         hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "zadania: porzadki maja tylko CEL (to, co przycinaja), zrodlo '-'"
else
    bad "zadania: porzadki zrodlo/cel" "$ZP"
fi
ZH2="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania --keys down 2>&1)"
if has "$ZH2" 'źródło      hdd/vm-disks/subvol-100-disk-0' && has "$ZH2" 'cel         pve9:hdd/backups'; then
    ok "zadania: dla WYSYLKI zrodlo jest tutaj, a cel u peera"
else
    bad "zadania: wysylka zrodlo/cel" "$ZH2"
fi
ZH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania 2>&1)"
if hasE "$ZH" '^║ pve9 +hostA>pve9 +wysyłka hourly' && hasE "$ZH" '^║ pve1 +hostA<pve1 +wysyłka hourly' && hasE "$ZH" '^║ \(bez rel\.\) +local +wysyłka daily'; then
    ok "zadania: wysylka = 'hostA>pve9', pobranie = 'hostA<pve1', kopia na hoscie = 'local'; zadanie bez etykiety mowi '(bez rel.)'"
else
    bad "zadania: trzy kierunki na hostA" "$ZH"
fi
ZE="$(screen zadania enter)"
if has "$ZE" '╔═ lab-vm101 ═' && has "$ZE" 'źródło   zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101' && has "$ZE" 'cel      hdd/backups/192.168.28.99/hdd/lab/vm-101' \
        && has "$ZE" 'szczebel standard_hourly  (sekcja dataset)' && has "$ZE" 'W CRONIE' && has "$ZE" 'snapget.sh'; then
    ok "zadania: Enter = panel (ze zrodlem i celem na gorze) + W CRONIE z prawdziwa linia"
else
    bad "zadania: Enter" "$ZE"
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
A="$(act down,F4)"
if has "$A" '╔═ POTWIERDZENIE: Wstrzymaj relację lab-ct201 ═' && has "$A" 'Wykona się DOKŁADNIE to:' \
        && has "$A" 'pause-client'; then   # the shell line WRAPS on a long checkout path (CI: /home/runner/work/...), so the verb and the name may sit on different lines
    ok "akcje: F4 na relacji aktywnej pokazuje komende pause-client PRZED wykonaniem"
else
    bad "akcje: F4 podglad pauzy" "$A"
fi
if [ ! -s "$XL" ]; then
    ok "akcje: ...i sam podglad NICZEGO nie uruchamia"
else
    bad "akcje: podglad nie uruchamia" "$(cat "$XL")"
fi
A="$(act down,F4,t)"
if grep -q "pause-client lab-ct201 '--reason=z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ] && has "$A" '╔═ WYJŚCIE: Wstrzymaj relację lab-ct201 ═' && has "$A" '[atrapa]'; then
    ok "akcje: 't' wykonuje DOKLADNIE pokazana komende (pause-client NAME --reason=...) i otwiera okno wyjscia"
else
    bad "akcje: t wykonuje" "$(cat "$XL")" "$A"
fi
A="$(act down,F4,esc)"
if [ ! -s "$XL" ] && has "$A" 'anulowano -- nic nie wykonano'; then
    ok "akcje: Esc w potwierdzeniu anuluje i mowi to; dziennik pusty"
else
    bad "akcje: Esc anuluje" "$(cat "$XL")" "$A"
fi
A="$(act down,F4,q)"
if [ ! -s "$XL" ] && has "$A" 'anulowano'; then
    ok "akcje: KAZDY klawisz poza 't' anuluje (tu: q) -- nie ma przypadkowego wykonania"
else
    bad "akcje: inny klawisz anuluje" "$(cat "$XL")" "$A"
fi
# pauza -> wznowienie: ta sama litera, przeciwny czasownik, decyduje REKORD
AP="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --exec-log "$XL" --screen relacje --keys down,down,down,F4,t 2>&1)"
if grep -q "resume-client lab-srv-b$" "$XL" && has "$AP" 'WYJŚCIE: Wznów relację lab-srv-b'; then
    ok "akcje: F4 na relacji WSTRZYMANEJ wola resume-client (decyduje paused_local z rekordu)"
else
    bad "akcje: F4 = resume na pauzie" "$(cat "$XL")" "$AP"
fi
# F4 na F3 to PAUZA, nie przelaczenie na Transfery
A="$(act F4)"
if ! has "$A" '╔═ Zakończone' && has "$A" 'POTWIERDZENIE'; then
    ok "akcje: F4 na ekranie Relacje to pauza, a nie skok do Transferow (tam F4 z innych ekranow)"
else
    bad "akcje: F4 na F3" "$A"
fi
# eksport: podpowiedz pelnej sciezki, do zmiany
A="$(HOME=/root act down,F7)"
if has "$A" '╔═ Eksport relacji lab-ct201 ═' && has "$A" 'lab-ct201.export.json_'; then
    ok "akcje: F7 podpowiada PELNA sciezke pliku eksportu (/root/<relacja>.export.json) i pozwala ja zmienic"
else
    bad "akcje: F7 podpowiedz" "$A"
fi
A="$(HOME=/root act down,F7,bs,bs,bs,bs,text:yaml,enter)"
if has "$A" 'POTWIERDZENIE: Eksport relacji lab-ct201' && has "$A" 'export-relation lab-ct201' && has "$A" 'lab-ct201.export.yaml'; then
    ok "akcje: ...Backspace i wpisany tekst zmieniaja sciezke, a komenda pokazuje przekierowanie do NIEJ"
else
    bad "akcje: F7 edycja sciezki" "$A"
fi
A="$(HOME=/root act down,F7,enter,t)"
if grep -q "export-relation lab-ct201 --json > .*lab-ct201.export.json'\?$" "$XL"; then
    ok "akcje: 't' wykonuje eksport DO wskazanego pliku"
else
    bad "akcje: F7 t" "$(cat "$XL")"
fi
# import: podglad (bez --yes) w potwierdzeniu, potem --yes
A="$(HOME=/root act down,F8,text:e.json,enter)"
if has "$A" 'POTWIERDZENIE: Import relacji z e.json' && has "$A" 'import-relation' && hasE "$A" "e.json'? --yes" && has "$A" '[atrapa] podgląd:'; then
    ok "akcje: F8 pyta o plik, pokazuje PODGLAD czasownika (bez --yes) i komende z --yes do potwierdzenia"
else
    bad "akcje: F8" "$A"
fi
A="$(HOME=/root act down,F8,text:e.json,enter,t)"
if grep -q "import-relation .*e.json'\? --yes$" "$XL"; then
    ok "akcje: ...i 't' wola import-relation PLIK --yes"
else
    bad "akcje: F8 t" "$(cat "$XL")"
fi
# odmowy PRZED czymkolwiek: rekord usuniety, wiersz bez rekordu, inny ekran
A="$(act end,F4)"; act end,F4,t >/dev/null
if [ ! -s "$XL" ] && has "$A" "relacja '192.168.28.99' jest już usunięta"; then
    ok "akcje: na rekordzie 'removed' PAUZA odmawia, mowi dlaczego, i nic nie idzie do powloki (Del tam dziala -- zwalnia nazwe)"
else
    bad "akcje: removed odmawia" "$(cat "$XL")" "$A"
fi
AH="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F4 2>&1)"
"$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F4,t >/dev/null 2>&1
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
A="$(act end,del)"
if grep -Eq "delete-relation 192.168.28.99 --ask\$" "$XL" && ! has "$A" 'jest już usunięta'; then
    ok "akcje: Del dziala takze na rekordzie 'removed' -- tam znaczy 'zwolnij nazwe / posprzataj reszte'"
else
    bad "akcje: Del na removed" "$(cat "$XL")" "$(printf '%s' "$A" | tail -3)"
fi
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
W="$(screen relacje down,enter)"
if has "$W" '╔═ Relacja lab-ct201 ═'; then
    ok "okno: Enter na wierszu otwiera okno relacji na wierzchu"
else
    bad "okno: otwarcie" "$W"
fi
if has "$W" 'Lądowiska  hdd/backups/192.168.28.99/hdd/lab/ct-201' && has "$W" 'Źródła (1) zfsbackup-pve10@192.168.28.99:hdd/lab/ct-201'; then
    ok "okno: zakres -- zrodla z rekordu i ladowiska (MANAGED_DATASETS)"
else
    bad "okno: zakres" "$W"
fi
W2="$(screen relacje down,enter --height 60)"
if has "$W2" 'zfs-backup.sh pause-client lab-ct201' && ! has "$W2" 'resume-client'; then
    ok "okno: komendy CLI dla relacji AKTYWNEJ: pause-client, bez resume-client"
else
    bad "okno: komendy dla stanu active" "$W2"
fi
# LINIE CRONA PO ETYKIECIE. Linia snapget dla pobrania nazywa zdalne zrodlo i
# RODZICA ladowiska, nigdy samo ladowisko -- dopasowanie po zakresie jej nie
# widzialo (zmierzone na pve10 2026-09-09). Klucz drugi: -L <etykieta>.
WC="$(screen relacje down,enter --height 60)"
if has "$WC" 'snapget.sh -m' && has "$WC" '-L lab-ct201' && has "$WC" 'delsnaps.sh -G -R -L'; then
    ok "okno: W CRONIE pokazuje linie snapget (po etykiecie -L), delsnaps i monitor -- to, co host naprawde wykona"
else
    bad "okno: linie crona po etykiecie" "$WC"
fi
if has "$WC" '30 * * * *    standard_hourly' && has "$WC" 'keep_monthly -M12'; then
    ok "okno: ...oraz sekcje configu z harmonogramem, szczeblem i retencja"
else
    bad "okno: sekcje configu w oknie" "$WC"
fi
WP="$(screen relacje down,down,down,down,enter --height 60)"
if has "$WP" 'wysyłka  hdd/backups/192.168.28.99/hdd/lab/vm-101   co: 24 * * * *' && has "$WP" 'stempel automated_hourly_' && has "$WP" 'trzyma -H24 -D7 -W4' && has "$WP" '-M12   co: 44 * * * *   drabina GFS' && has "$WP" 'porządki zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101'; then
    ok "okno: POLITYKA z show-config -- wysylka i porzadki z retencja zlozona z szablonow"
else
    bad "okno: polityka z show-config" "$WP"
fi
WS="$(screen relacje enter --height 60)"
if has "$WS" 'zfs-backup.sh activate duplikat'; then
    ok "okno: relacja w zasiewie nazywa 'activate' (wznawialne dokonczenie cyklu)"
else
    bad "okno: komendy dla stanu seeding" "$WS"
fi
WPZ="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down,enter,end 2>&1)"
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
if has "$W" 'Esc zamyka   strzałki/PgUp/PgDn przewijają   1-21 z'; then
    ok "okno: stopka mowi, jak wyjsc i ile jest do przewiniecia"
else
    bad "okno: stopka" "$W"
fi

# ============================================================================
# TRANSFERY
# ============================================================================
T="$(screen transfery)"
if has "$T" '╔═ W toku (0) ═' && has "$T" 'nic nie leci teraz' && has "$T" '╔═ Zakończone (14) ═'; then
    ok "transfery: dwie ramki -- w toku (puste, powiedziane) i zakonczone z licznikiem"
else
    bad "transfery: ramki" "$T"
fi
if hasE "$T" '^║ lab-srv-b +hdd/lab/srv-b/www +przyrost\. +- +OK +[0-9:]+ 0 s +║'; then
    ok "transfery: wiersz = relacja, dataset (bez @migawki), tryb, dane, stan, kiedy"
else
    bad "transfery: wiersz transferu" "$T"
fi
if has "$T" 'na łączu: niemierzalne'; then
    ok "transfery: panel mowi 'niemierzalne', nie zero, gdy wire_bytes=-1"
else
    bad "transfery: niemierzalne" "$T"
fi
TF="$(screen zadania F4)"
if has "$TF" '╔═ Zakończone' && has "$TF" '[F4 Transfery]'; then
    ok "transfery: F4 z innego ekranu przelacza i podswietla klawisz w listwie"
else
    bad "transfery: F4" "$TF"
fi
TW="$(screen transfery down,enter)"
if has "$TW" '╔═ transfer lab-srv-b ═' && has "$TW" 'Migawka  hdd/lab/srv-b/db@automated_hourly'; then
    ok "transfery: Enter otwiera szczegoly wiersza pod kursorem jako okno"
else
    bad "transfery: Enter" "$TW"
fi

# ============================================================================
# MONITOR
# ============================================================================
M="$(screen monitor)"
if has "$M" '╔═ Monitor -- 4 linie, najgorzej: aktualne ═'; then
    ok "monitor: tytul liczy linie i nazywa najgorszy werdykt slowem"
else
    bad "monitor: tytul" "$M"
fi
if hasE "$M" '^║ lab-vm101 +….*hdd/lab/vm-101 +automated_hourly +90m/150m +aktualne +║'; then
    ok "monitor: wiersz = relacja, dataset, rodzina, progi, werdykt slowem"
else
    bad "monitor: wiersz" "$M"
fi
MP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen monitor --keys end 2>&1)"
if hasE "$MP" '^║ lab-srv-b .*aktualne PAUZA +║' && has "$MP" 'OK -- relationship lab-srv-b is paused'; then
    ok "monitor: linia wstrzymana ma PAUZA przy werdykcie, a panel cytuje zdanie silnika o pauzie"
else
    bad "monitor: pauza" "$MP"
fi
MH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen monitor --keys down 2>&1)"
if hasE "$MH" '^║ pve1 .*stare +║' && has "$MH" 'spóźnione' && has "$MH" 'Uwaga        cron woła /r/check-snap-age.sh'; then
    ok "monitor: CRITICAL/WARNING slowami, posortowane od najgorszego, i ostrzezenie o innym pliku silnika w cronie"
else
    bad "monitor: hostA" "$MH"
fi
ME="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/empty.json" --monitors "$FIX/empty-mon.json" --screen monitor 2>&1)"
if has "$ME" 'NIKT nie sprawdza'; then
    ok "monitor: zero linii monitora jest nazwane wprost, nie pusta ramka"
else
    bad "monitor: pusty" "$ME"
fi

# ============================================================================
# NOSNIKI
# ============================================================================
N="$(screen nosniki)"
if hasE "$N" '^║ sejf-a +hdd/lab → bkp/sejf-a +30 2 \* \* \* +W SEJFIE +nigdy +║' && hasE "$N" '^║ sejf-b +hdd/lab,hdd/backups → rpool/… +po włożeniu +W SEJFIE'; then
    ok "nosniki: wiersz = replika, zrodlo -> cel, harmonogram (on-insert po polsku), stan nosnika SLOWEM, ostatnio widziany"
else
    bad "nosniki: wiersze" "$N"
fi
# KONTROLA CZYTELNIKA: sejf-b nie ma linii `media` (--fixed). Stary list-replicas
# zwracal media="yes", recursive="latest" -- pola przesuniete o jedno przez
# IFS=tab. Fikstura pochodzi z NAPRAWIONEGO czytelnika i ten ekran to przypina.
NB="$(screen nosniki down)"
if has "$NB" 'sejf-b -- szczegóły' && has "$NB" 'Harmonogram po włożeniu nośnika   stempel automated_   rekursywnie' && has "$NB" 'historia: latest'; then
    ok "nosniki: panel repliki --fixed ma rekursje i historie na SWOICH miejscach (kontrola przesuniecia pol list-replicas)"
else
    bad "nosniki: pola repliki --fixed" "$NB"
fi
if has "$NB" 'Nośnik      W SEJFIE -- nośnika nie ma w maszynie'; then
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

# ============================================================================
# LINIA POLECEN (wlasciciel 2026-09-11: "chcemy moc w kazdej chwili pisac
# komendy z palca"). Nad listwa klawiszy, na KAZDYM ekranie; styl mc.
# ============================================================================
cl_ok=1
for sc in zadania relacje transfery monitor nosniki; do
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
if hasE "$C" '@pve10:zfs-snapshot-all\$ abc_ *$' && has "$C" 'duplikat -- szczegóły'; then
    ok "linia: z tekstem w linii strzalki NIE ruszaja listy (kursor zostaje na pierwszym wierszu)"
else
    bad "linia: strzalki przy tekscie" "$C"
fi
# 'e' w potwierdzeniu: komenda akcji laduje w linii do poprawki, nic nie rusza.
C="$(: > "$XL"; screen relacje "down,F4,e" --exec-log "$XL")"
if has "$C" "pause-client lab-ct201 '--reason=z TUI" && ! has "$C" 'POTWIERDZENIE' && [ ! -s "$XL" ] && has "$C" 'komenda w linii poleceń -- popraw i Enter'; then
    ok "linia: 'e' w potwierdzeniu wrzuca pokazana komende do linii polecen (podglad + edycja), dziennik pusty"
else
    bad "linia: e w potwierdzeniu" "$C" "$(cat "$XL")"
fi
C="$(: > "$XL"; screen relacje "down,F4,e,bs,bs,bs,bs,bs,bs,enter" --exec-log "$XL")"
if grep -q "pause-client lab-ct201 '--reason=z TUI" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ]; then
    ok "linia: ...poprawiona (6 x Backspace) i Enter wykonuje TO, co w linii"
else
    bad "linia: e + edycja + Enter" "$(cat "$XL")" "$C"
fi
C="$(: > "$XL"; screen relacje "q,text:uit" --exec-log "$XL")"
if hasE "$C" '@pve10:zfs-snapshot-all\$ quit_ *$' && has "$C" 'Relacje na kolektorze'; then
    ok "linia: litera 'q' na ekranie to TEKST, nie wyjscie (zmierzone na pve9: 'echo' dawalo 'cho', gdy 'e' bylo skrotem)"
else
    bad "linia: q jest tekstem" "$C"
fi
C="$(: > "$XL"; screen relacje "text:zfs list,F10" --exec-log "$XL")"
if [ ! -s "$XL" ]; then
    ok "linia: F10 wychodzi takze z tekstem w linii, nic nie uruchamiajac"
else
    bad "linia: F10" "$(cat "$XL")"
fi
rm -f "$XL"

# ============================================================================
# KONTRAKT WYGLADU: 80 to przypadek projektowy, 120 i 200 wykorzystuja miejsce
# ============================================================================
widths_ok=1
for w in 80 120 200; do
    for sc in zadania relacje transfery monitor nosniki; do
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
        && has "$S" '╔═ Datasety relacji' && has "$S120" '╔═ Datasety relacji'; then
    ok "wyglad: F3 w trzech panelach przy 80 i 120 -- lista, panel obok, pary na dole"
else
    bad "wyglad: trzy panele" "$S" "$S120"
fi
# Terminal bez UTF-8: ramki +-|= i slowa bez ogonkow. Zero bajtow spoza ASCII.
ascii_ok=1
for sc in zadania relacje transfery monitor nosniki; do
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
if hasE "$A" '^\| lab-ct201 +pve10<192.168.28.99 +active +\|' && has "$A" 'Datasety relacji duplikat: 1 para, wg rekordu, nie crona' && has "$A" '192.168.28.99:hdd/lab/vm-101 -> hdd/backups/192.168.28.99/hdd/lab/vm-101'; then
    ok "wyglad: w ASCII te same slowa (aktualne, Zrodla) -- werdykt niesie slowo, nie tylko kolor"
else
    bad "wyglad: slowa w ASCII" "$A"
fi
HLP="$(screen relacje F1 --height 60)"
if has "$HLP" '╔═ Pomoc ═' && has "$HLP" 'bez monitora   NIKT nie pyta' && has "$HLP" 'NAJPIERW komenda bash'; then
    ok "pomoc: F1 otwiera pomoc ze slownikiem kolumny Kopie"
else
    bad "pomoc: F1" "$HLP"
fi
if has "$S" 'F1 Pomoc F2 Zadania [F3 Relacje] F4 Transfery F5 Monitor F6 Nośniki F10 Wyjście'; then
    ok "wyglad: listwa F-klawiszy miesci sie w 80 kolumnach i podswietla aktywny ekran"
else
    bad "wyglad: listwa F" "$S"
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
XM="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --monitors "$BROKEN" --screen monitor 2>&1)"
XN="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --replicas "$BROKEN" --screen nosniki 2>&1)"
if has "$XT" 'błąd źródła: progress --json' && has "$XM" 'błąd źródła: monitor --json' && has "$XN" 'błąd źródła: list-replicas --json'; then
    ok "ujemna: kazdy z pozostalych ekranow nazywa SWOJE zepsute zrodlo"
else
    bad "ujemna: zepsute zrodla na pozostalych ekranach" "$XT" "$XM" "$XN"
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
    status)         if [ -e "$NR_DIR/freed-192.168.28.99" ]; then sed 's/"name": *"192.168.28.99"/"name":"zwolniona"/' "$NR_FIX/status.json"
                    elif [ -n "${NR_FLAT:-}" ]; then sed 's/"profile": *"default"/"profile":"d30h24"/g' "$NR_FIX/status.json"     # kolektor "plaski"
                    else cat "$NR_FIX/status.json"; fi ;;
    --source=*)     case " $* " in
                        *" --install "*) case " $* " in
                                *" --grant-remotely "*) echo ">>> atrapa: zainstalowano"; exit 0 ;;
                                *) echo "FATAL: the source has GRANTED nothing yet: on the source run"; echo "    deploy.sh --commit-scope=pve10"; exit 1 ;;
                            esac ;;
                        *) echo "RUX plan (atrapa)"; exit 0 ;;
                    esac ;;
    prepare-source) : > "$NR_DIR/installed"; echo "prepared" ;;
    *)              echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
chmod +x "$NR/bin/whiptail" "$NR/bin/zb"
nr_run() {   # <plik odpowiedzi jako tekst> [ENV=...] -> stdout kreatora; dzienniki w $NR
    rm -f "$NR/wt.log" "$NR/wt.n" "$NR/zb.log" "$NR/installed" "$NR"/freed-* "$NR"/new-relation-*.cmd
    printf '%s' "$1" > "$NR/answers"; shift
    ( export HOME="$NR" NR_DIR="$NR" NR_FIX="$P10" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb" PYTHON="$PY" "$@"; bash "$NRS" ) 2>"$NR/err" </dev/null
    local rc=$?
    grep -- ' --install --yes$' "$NR/zb.log" 2>/dev/null | sed 's/^/CMD: /; s/$/ /'
    return "$rc"
}
T=$'\t'
# Kroki 5-10 z domyslnymi odpowiedziami: cel, szablon, nazwa, konto, checklista ustawien, plan, WYKONAJ
NRT="0${T}hdd/backups
0${T}no
0${T}default
0${T}pve9b
0${T}root
0${T}grant|skip
0${T}
0${T}
"
NRTS="0${T}no
0${T}default
0${T}pve9b
0${T}root
0${T}grant|skip
0${T}
0${T}
"
# KOSZYK MIEJSC (2026-09-18, trzecia wersja tego dnia). Wlasciciel: jedna lista kratek
# byla mylaca; pytanie "co kopiowac?" tylko dla datasetow z dziecmi tez -- "czysty
# Proxmox, wskazuje rpool/data, zeby kopiowal maszyny, ktorych tam jeszcze nie ma".
# Zmierzone na pve10<-pve11: dataset zalozony pod zrodlem PO relacji kopiuje sie sam,
# w -R i w -r. Pozycja = MIEJSCE; dodanie nie zadaje pytan; wyjatki to akcja koszyka.
# 1. miejsce z dziecmi + wyjatek + puste miejsce
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/data
0${T}exc
0${T}hdd/data/docs|hdd/data/photos
0${T}add
0${T}hdd/test-kreator
0${T}next
${NRT}"); NRRC=$?
if [ "$NRRC" -eq 0 ] && has "$NROUT" "CMD: --source=192.168.28.98:hdd/data,hdd/test-kreator --target=hdd/backups --profile=default --name=pve9b --exclude-child=^hdd/data/mail\$ --exclude-family=__replicate_,vzdump,__migration__ --grant-remotely --install --yes " && ! has "$NROUT" "--recursive" && ! hasE "$NROUT" 'exclude-child=[^ ]*[(|]'; then
    ok "new-relation: koszyk -- miejsca w JEDNYM --source po przecinku, odznaczone dziecko jako --exclude-child=^nazwa\$ (zakotwiczone, bez ( | -- wzorzec jedzie nieocytowany do crona)"
else
    bad "new-relation: koszyk, droga glowna" "rc=$NRRC" "$NROUT" "$(cat "$NR/err")" "$(cat "$NR/wt.log")"
fi
if ! grep -qF -- '--radiolist' <(grep -F 'Krok 4/10' "$NR/wt.log") && ! grep -qF 'Jak kopiować' "$NR/wt.log"; then
    ok "new-relation: dodanie miejsca NIE zadaje pytan -- w kroku 4 nie ma ani 'co kopiowac?', ani -R/-r (to 'jak', nie 'co')"
else
    bad "new-relation: pytanie w kroku 4" "$(grep -F -- '--radiolist' "$NR/wt.log")"
fi
NRMENU2="$(grep -F -- 'Które miejsce z' "$NR/wt.log" | sed -n 2p)"
if [ -n "$NRMENU2" ] && ! has "$NRMENU2" "hdd/data ~" && ! has "$NRMENU2" "hdd/data/docs ~" && has "$NRMENU2" "hdd/ct ~" \
   && grep -F -- 'Które miejsce z' "$NR/wt.log" | head -1 | grep -qE 'hdd/data ~   data +[0-9.]+[KMG] +3 pod nim ~' \
   && grep -F -- 'Które miejsce z' "$NR/wt.log" | head -1 | grep -qE 'vm-201-disk-0 +[0-9.]+[KMGB] +zvol' \
   && grep -F -- 'Które miejsce z' "$NR/wt.log" | head -1 | grep -qF 'albo POWSTANIE'; then
    ok "new-relation: lista miejsc = drzewo (wciecie, rozmiar, zvol, 'N pod nim') i mowi wprost 'albo POWSTANIE'; tego, co koszyk juz obejmuje, druga lista NIE pokazuje"
else
    bad "new-relation: lista miejsc" "$NRMENU2" "$(grep -F -- 'Które miejsce z' "$NR/wt.log" | head -1)"
fi
NRB="$(grep -F -- 'Co kopiować z' "$NR/wt.log" | tail -1)"
if has "$NRB" 'POMIJANE: mail' && has "$NRB" 'dziś pod nim: docs, photos' && has "$NRB" 'dziś nic pod nim' && [ "$(printf '%s' "$NRB" | grep -o 'wszystko, co pod nim POWSTANIE' | wc -l)" -eq 2 ]    && has "$NRB" 'Sposób: każdy dataset osobno (-R) -- zmień'; then
    ok "new-relation: okno koszyka POKAZUJE, co dzis lezy pod miejscem, pomijane ZAWSZE w calosci ('POMIJANE: mail', takze na 24 wierszach), o pustym mowi 'dzis nic pod nim', przy kazdym '+ wszystko, co pod nim POWSTANIE'; -R/-r jako akcja koszyka"
else
    bad "new-relation: okno koszyka" "$NRB"
fi
if grep -F -- 'czego NIE kopiować' "$NR/wt.log" | grep -qF 'hdd/data/docs ~' && grep -F -- 'czego NIE kopiować' "$NR/wt.log" | grep -qF ' ~ ON ~ ' \
   && ! grep -F -- 'czego NIE kopiować' "$NR/wt.log" | grep -qF 'hdd/ct'; then
    ok "new-relation: wyjatki = lista TYLKO tego, co pod wybranym miejscem, wszystko zaznaczone (kopiowane) na starcie"
else
    bad "new-relation: lista wyjatkow" "$(grep -F -- 'czego NIE kopiować' "$NR/wt.log")"
fi
# 2. puste miejsce samo: akcji 'Wyjatki' NIE MA (przyszlego nie da sie wskazac), synchro z portem
NROUT=$(nr_run "0${T}sync
0${T}192.168.28.98:2222
0${T}
0${T}hdd/test-kreator
0${T}next
${NRTS}")
if has "$NROUT" "CMD: --source=192.168.28.98:2222:hdd/test-kreator --mode=sync --profile=default --name=pve9b --exclude-family=" && ! has "$NROUT" "--target" && ! has "$NROUT" "exclude-child" && grep -q '^check-source 192.168.28.98:2222 --json$' "$NR/zb.log" \
   && ! grep -F -- 'Co kopiować z' "$NR/wt.log" | grep -qF ' ~ exc ~ '; then
    ok "new-relation: miejsce, pod ktorym dzis nic nie ma -> koszyk BEZ akcji 'Wyjatki'; synchro = --mode=sync, port w adresie"
else
    bad "new-relation: puste miejsce / synchro" "$NROUT" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log")"
fi
# 3. wyjatki otwarte drugi raz pamietaja stan (odznaczone wraca odznaczone)
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/ct
0${T}exc
0${T}hdd/ct/subvol-301-disk-0
0${T}exc
1${T}
0${T}next
${NRT}")
if has "$NROUT" " --exclude-child=^hdd/ct/subvol-302-disk-0\$ " && grep -F -- 'czego NIE kopiować' "$NR/wt.log" | tail -1 | grep -qE 'hdd/ct/subvol-302-disk-0 ~ [^~]* ~ OFF' \
   && grep -F -- 'czego NIE kopiować' "$NR/wt.log" | tail -1 | grep -qE 'hdd/ct/subvol-301-disk-0 ~ [^~]* ~ ON'; then
    ok "new-relation: ponowne 'Wyjatki' pokazuja stan (pomijany = odznaczony); Wstecz niczego nie zmienia"
else
    bad "new-relation: stan wyjatkow" "$NROUT" "$(grep -F -- 'czego NIE kopiować' "$NR/wt.log")"
fi
# 3b. miejsce dodane PO swoim dziecku: pytanie o zastapienie, bez sprzecznosci w komendzie
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/data/docs
0${T}add
0${T}hdd/data
0${T}
0${T}next
${NRT}")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/data --target" && ! has "$NROUT" "hdd/data/docs" && grep -F -- '--yesno' "$NR/wt.log" | grep -F 'obejmuje to, co już wybrane' | grep -qF 'hdd/data/docs'; then
    ok "new-relation: miejsce dodane po wlasnym dziecku -> pytanie 'Zastap' z NAZWA dziecka; w komendzie zostaje samo miejsce"
else
    bad "new-relation: zastapienie dziecka miejscem" "$NROUT" "$(grep -F -- '--yesno' "$NR/wt.log")"
fi
# 3c. pominiety dataset Z WLASNYMI dziecmi = dwa wzorce: ^nazwa$ i ^nazwa/
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd
0${T}exc
0${T}hdd/ct/subvol-301-disk-0|hdd/ct/subvol-302-disk-0|hdd/data|hdd/data/docs|hdd/data/mail|hdd/data/photos|hdd/db|hdd/db/postgres|hdd/home|hdd/home/adam|hdd/home/ewa|hdd/test-kreator|hdd/vm-disks|hdd/vm-disks/vm-201-disk-0|hdd/vm-disks/vm-202-disk-0
0${T}next
${NRT}")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd --target=hdd/backups --profile=default --name=pve9b --exclude-child=^hdd/ct\$ --exclude-child=^hdd/ct/ --exclude-family" && [ "$(printf '%s' "$NROUT" | grep '^CMD: ' | grep -o 'exclude-child' | wc -l)" -eq 2 ]; then
    ok "new-relation: odznaczony dataset z dziecmi = ^nazwa\$ i ^nazwa/ (jego dzieci nie dostaja wlasnych wzorcow, choc zostaly zaznaczone)"
else
    bad "new-relation: pominiety z dziecmi" "$NROUT"
fi
# 3d. usuniecie jedynej pozycji -> znow lista miejsc; Wstecz x3 = wyjscie
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/test-kreator
0${T}del
0${T}0
1${T}
1${T}
1${T}
"); NRRC=$?
if [ "$NRRC" -eq 1 ] && [ "$(grep -cF -- 'Które miejsce z' "$NR/wt.log")" -eq 2 ] && grep -F -- 'Które miejsce z' "$NR/wt.log" | tail -1 | grep -qF 'hdd/test-kreator ~'; then
    ok "new-relation: 'Usun pozycje' oproznia koszyk -> wraca lista miejsc Z usunietym datasetem; Wstecz prowadzi do hosta i wyjscia"
else
    bad "new-relation: usuwanie z koszyka" "rc=$NRRC" "$(cat "$NR/wt.log")"
fi
# 3e. kroki 5-10: nazwa zajeta -> odmowa i powrot do pola; Wstecz i ponowne Dalej NIE czytaja od nowa
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/test-kreator
0${T}next
0${T}hdd/backups
0${T}no
0${T}default
0${T}lab-ct201
0${T}
1${T}
0${T}yes
0${T}d30
0${T}pve9b
0${T}zfsbackup
0${T}grant|quies|skip
0${T}
0${T}
")
if has "$NROUT" "CMD: --source=192.168.28.98:hdd/test-kreator --target=hdd/backups --profile=d30 --name=pve9b --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --grant-remotely --grant-quiesce --install --yes " \
   && grep -qF 'Nazwa zajęta' "$NR/wt.log" && [ "$(grep -c '^list-profiles' "$NR/zb.log")" -eq 1 ] && [ "$(grep -c '^status' "$NR/zb.log")" -eq 1 ]; then
    ok "new-relation: kroki 5-10 -- zajeta nazwa odmowiona, Wstecz z nazwy do szablonu zmienia wybor (d30), konto delegowane = --local-user; list-profiles i status czytane RAZ na przebieg (cofanie nie kaze czekac od nowa)"
else
    bad "new-relation: kroki 5-10" "$NROUT" "$(cat "$NR/zb.log")" "$(grep -F 'Nazwa' "$NR/wt.log" | cut -c1-200)"
fi
NRL1="$(grep -F 'Jak długo trzymać?' "$NR/wt.log" | head -1)"; NRL2="$(grep -F 'Jak długo trzymać?' "$NR/wt.log" | tail -1)"
if grep -F 'Spójność migawek' "$NR/wt.log" | head -1 | grep -qE 'yes ~ Zamrażaj przy migawkach dobowych i rzadszych  -- zalecane ~ ON ~ no ~ [^~]* ~ OFF' \
   && has "$NRL1" 'Szablony BEZ zamrażania' && has "$NRL1" ' ~ default ~ default ' && ! has "$NRL1" ' ~ d30h24 ~ ' \
   && has "$NRL2" 'Szablony ZAMRAŻAJĄCE dobowe i rzadsze (godzinowe bez)' && has "$NRL2" ' ~ d30 ~ ' && has "$NRL2" '--default-item ~ m12w4d7h24-gfs' && ! has "$NRL2" ' ~ default ~ default '; then
    ok "new-relation: krok 6 -- zamrazanie WIDAC przy tworzeniu relacji: najpierw pytanie o spojnosc (domyslnie ZAMRAZAJ wszystko oprocz godzinowych), potem lista tylko szablonow, ktore to spelniaja; 'default' (drabina, zamrazac nie moze) jest tylko na liscie 'bez'"
else
    bad "new-relation: krok 6, zamrazanie" "$(grep -F 'Spójność migawek' "$NR/wt.log" | head -1 | cut -c1-300)" "$(printf '%s' "$NRL1" | cut -c1-300)" "$(printf '%s' "$NRL2" | cut -c1-300)"
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
# 3g. nazwa trzymana przez rekord `removed`: zmierzone na pve10 -- plan mowil "removed and
#     cannot be revived", a kreator i tak pokazywal WYKONAJ. Teraz pyta o zwolnienie nazwy.
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/test-kreator
0${T}next
0${T}hdd/backups
0${T}no
0${T}default
0${T}192.168.28.99
0${T}
0${T}root
0${T}grant|skip
0${T}
0${T}
")
if has "$NROUT" " --name=192.168.28.99 " && grep -q '^delete-relation 192.168.28.99 --yes$' "$NR/zb.log" && grep -F "trzyma USUNIĘTA relacja" "$NR/wt.log" | grep -qF -- '--yes-button ~ Zwolnij nazwę'; then
    ok "new-relation: nazwe trzymana przez rekord 'removed' kreator proponuje ZWOLNIC (delete-relation NAZWA --yes) i dopiero wtedy jej uzywa -- 'usun i zaloz od nowa' dziala"
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

# 3i. KROK 9 TO CHECKLISTA, NIE EDYTOR Z WIERSZEM-WYJSCIEM.
#
# Wlasciciel, 2026-09-20, po zobaczeniu ekranu na zywo: "krok 9/10 nie przechodzi
# dalej -- mozna tylko dac wstecz lub wejsc do podswietlonej pozycji", a o wierszu
# "Bez zmian, dalej": "to jest potworek. Ma byc przycisk Dalej, wstecz a wybiera
# sie enterem na liscie". Whiptail (newt 0.52.23) ma DWA przyciski, wiec ekran,
# ktory jednoczesnie edytuje pozycje i ma Dalej, jest niewykonalny -- stad
# checklista: spacja przelacza, Enter = Dalej. ZADNA pozycja listy nie moze byc
# pseudo-akcja "dalej".
NRL="$(grep -F 'Krok 9/10: Ustawienia dodatkowe' "$NR/wt.log" | head -1)"
if has "$NRL" '--checklist' && has "$NRL" -- '--ok-button ~ Dalej ~' && has "$NRL" -- '--cancel-button ~ Wstecz ~' \
   && ! has "$NRL" 'Bez zmian' && ! has "$NRL" 'DALEJ --' && has "$NRL" 'SPACJA przełącza'; then
    ok "new-relation: krok 9 to CHECKLISTA z przyciskami Dalej/Wstecz -- zadna pozycja listy nie udaje przycisku 'dalej' (wlasciciel, 2026-09-20)"
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

# 3h. KOLEKTOR MA KSZTALT: gdy zywa relacja uzywa szablonu "rodzina na szczebel", aktywacja
#     szablonu-drabiny jest odmawiana ("This host reads as FLAT ... NO RETENTION AT ALL",
#     zmierzone na pve10). Kreator nie moze ich wtedy oferowac ani pytac o "bez zamrazania".
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/test-kreator
0${T}next
0${T}hdd/backups
0${T}d7h24
0${T}pve9b
0${T}root
0${T}grant|quies|skip
0${T}
0${T}
" NR_FLAT=1)
NRL="$(grep -F 'Jak długo trzymać?' "$NR/wt.log" | head -1)"
if has "$NROUT" " --profile=d7h24 " && ! grep -qF 'Spójność migawek' "$NR/wt.log" && has "$NRL" "szablony-" && has "$NRL" "nie dadzą się tu aktywować" \
   && ! has "$NRL" ' ~ default ~ ' && ! has "$NRL" ' ~ Y5M12D31H24 ~ ' && ! has "$NRL" ' ~ passive ~ ' && has "$NRL" ' ~ d30 ~ '; then
    ok "new-relation: na kolektorze, ktory ma juz relacje z szablonem bez drabiny, kreator NIE oferuje szablonow-drabin (default, Y5..., passive) i nie pyta o 'bez zamrazania' -- aktywacja by je odrzucila; okno mowi dlaczego"
else
    bad "new-relation: ksztalt kolektora" "$NROUT" "$(printf '%s' "$NRL" | cut -c1-500)" "$(cat "$NR/err")"
fi
# 3f. 'Zatwierdze sam na zrodle': instalacja MA stanac -- to nie awaria, tylko dwa kroki do zrobienia
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}hdd/test-kreator
0${T}next
0${T}hdd/backups
0${T}no
0${T}default
0${T}pve9b
0${T}root
0${T}skip
0${T}
0${T}
"); NRRC=$?
if [ "$NRRC" -eq 1 ] && has "$NROUT" "ZATRZYMANE ZGODNIE Z WYBOREM" && has "$NROUT" "deploy.sh --commit-scope=pve10" && ! has "$NROUT" "NIE UDAŁO SIĘ" \
   && has "$NROUT" "CMD: " && ! has "$(printf '%s' "$NROUT" | grep '^CMD: ')" "--grant-remotely" && grep -q -- "--install --yes" "$NR/new-relation-pve9b.cmd"; then
    ok "new-relation: 'Zatwierdze sam' -> komenda BEZ --grant-remotely, instalacja staje i kreator mowi 'ZATRZYMANE ZGODNIE Z WYBOREM' z dwoma krokami (nie 'NIE UDALO SIE'); komenda do ponowienia zapisana w pliku"
else
    bad "new-relation: zatwierdze sam" "rc=$NRRC" "$NROUT" "$(ls "$NR")"
fi
# 4. host, z ktorym relacja JEST: odmowa ze slowem dlaczego, potem Wstecz, Wyjdz
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.99
0${T}
1${T}
1${T}
"); NRRC=$?
if [ "$NRRC" -eq 1 ] && has "$NROUT" "przerwane, nic nie zmieniono" && grep -F 'Ta relacja już istnieje' "$NR/wt.log" | grep -qF 'lab-ct201' \
   && ! grep -F 'Ta relacja już istnieje' "$NR/wt.log" | grep -qF ': 192.168.28.99,' && ! grep -q '^check-source' "$NR/zb.log"; then
    ok "new-relation: host z istniejaca relacja = odmowa z nazwami relacji (rekord 'removed' sie nie liczy), bez sondy SSH; Wstecz z kroku 1 = wyjscie rc=1"
else
    bad "new-relation: istniejaca relacja" "rc=$NRRC" "$NROUT" "$(cat "$NR/wt.log")" "$(cat "$NR/zb.log")"
fi
# 5. brak pakietu: pytanie -> prepare-source --yes -> ponowna sonda -> dalej
NROUT=$(nr_run "0${T}backup
0${T}192.168.28.98
0${T}
0${T}
0${T}hdd/test-kreator
0${T}next
${NRT}" NR_CHECK=check-source.json)
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
if [ "$NRRC" -ne 0 ] && has "$NROUT" "przerwane, nic nie zmieniono" && grep -qF 'Krok 1/10: Jaka relacja?' "$NR/wt.log"; then
    ok "new-relation: czasownik zfs-backup.sh new-relation otwiera kreator na kroku 1; Wyjdz = nic nie zmieniono, rc != 0"
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
