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
if has "$S4" 'Datasety relacji lab-vm101: 1 para, wg crona   [źródło → cel | Kopie | Czas o/ś/m | GB]' \
        && hasE "$S4" '^║ zfsbackup-pve10@192.168.28.99:hdd/lab/vm-101 → hdd/backups/192.168.28.99/hdd/lab/vm-101 +aktualne +[0-9/]+s +[0-9.]+[KMG] +║'; then
    ok "relacje: dolny panel przy 200 -- para w jednej linii z kopiami, czasem o/s/m i GB"
else
    bad "relacje: pary przy 200" "$S4"
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
A="$(act down,del)"
if has "$A" 'POTWIERDZENIE: Usuń relację lab-ct201' && has "$A" 'remove-client lab-ct201' && has "$A" 'KOPII na dysku nie rusza'; then
    ok "akcje: Del pokazuje remove-client i mowi, czego NIE robi (kopii nie rusza)"
else
    bad "akcje: Del" "$A"
fi
A="$(act down,del,t)"
if grep -q "remove-client lab-ct201$" "$XL"; then
    ok "akcje: ...i po 't' wola dokladnie remove-client NAME"
else
    bad "akcje: Del t" "$(cat "$XL")"
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
A="$(act end,del)"; act end,del,t >/dev/null
if [ ! -s "$XL" ] && has "$A" "relacja '192.168.28.99' jest już usunięta"; then
    ok "akcje: na rekordzie 'removed' akcja odmawia, mowi dlaczego, i nic nie idzie do powloki"
else
    bad "akcje: removed odmawia" "$(cat "$XL")" "$A"
fi
AH="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --wizard curses --exec-log "$XL" --screen relacje --keys F4 2>&1)"
"$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --wizard curses --exec-log "$XL" --screen relacje --keys F4,t >/dev/null 2>&1
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
A="$(act down,ins --wizard curses)"
if has "$A" '╔═ Nowa relacja -- krok 1/8: Typ relacji' && [ ! -s "$XL" ]; then
    ok "akcje: --wizard curses zostawia stary kreator dla jego suity (do usuniecia razem z nia)"
else
    bad "akcje: Ins --wizard curses" "$A"
fi
# ============================================================================
# KREATOR NOWEJ RELACJI (Ins) -- NA LISTACH, wg makiety wlasciciela (2026-09-14)
# ============================================================================
# "Kroki sa dobre, ale galkologia wewnatrz jest do bani." Jedna regula klawiszy:
# strzalki, Enter = wybierz/zaznacz/dalej, Esc = wstecz, pisanie = filtr.
# Relacja = para hostow: nowa = host bez relacji (pve9 szary). Po hoscie
# diagnoza (check-source), brak pakietu = prepare-source. Datasety: wiele,
# drzewo. Fikstury: doslowne wyjscia z pve10 (check-source na pve9b z pakietem
# i BEZ -- ten drugi zebrany z SOURCE_REPO_DIR wskazujacym nieistniejacy
# katalog, bo w labie kazdy host ma juz pakiet; list-datasets pve9b; szablony).
wiz() {   # <keys> [extra] -> ekran; dziennik w $XL; host z pakietem
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --datasets-local "$P10/list-datasets.json" --datasets-remote "$P10/list-datasets-pve9b.json" --check-source "$P10/check-source-pkg.json" --wizard curses --exec-log "$XL" --screen relacje --keys "$1" "${@:2}" 2>&1
}
wizn() {  # jak wiz, ale host BEZ pakietu
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --datasets-local "$P10/list-datasets.json" --datasets-remote "$P10/list-datasets-pve9b.json" --check-source "$P10/check-source.json" --wizard curses --exec-log "$XL" --screen relacje --keys "$1" "${@:2}" 2>&1
}
W="$(wiz ins --width 110)"
if has "$W" '╔═ Nowa relacja -- krok 1/8: Typ relacji ═' && has "$W" '> backup    pobranie na ten host: kopie pod <cel>/<peer>/…, retencja tutaj (add-client)' \
        && has "$W" '  synchro   obie strony trzymają to samo pod TĄ SAMĄ ścieżką, bez celu (--mode=sync)' && has "$W" 'Esc = anuluj'; then
    ok "kreator: krok 1 = typ relacji -- backup (pobranie) albo synchro (--mode=sync), kursor na backup"
else
    bad "kreator: typ relacji" "$W"
fi
W="$(wiz ins,enter --width 110)"
if has "$W" '╔═ Nowa relacja -- krok 2/8: Z którego hosta? ═' && has "$W" '> 192.168.28.99     relacje: duplikat, lab-ct201, lab-srv-a, lab-srv-b, lab-vm101 -- kolejne datasety' \
        && has "$W" 'inny host…        wpisz adres; pakiet nie musi tam być' && has "$W" '↑↓ wybór   Enter = wybierz i dalej   Esc = wstecz   pisz = filtruj listę' && [ ! -s "$XL" ]; then
    ok "kreator: krok 2 = lista hostow; host z relacja jest na liscie z nazwami relacji, 'inny host' wpuszcza adres; stopka = jedna regula klawiszy"
else
    bad "kreator: krok 1" "$W"
fi
W="$(wiz ins,enter,enter --width 110)"
if has "$W" '! z 192.168.28.99 relacja już jest; kolejne datasety = modyfikacja relacji (CLI jeszcze nie umie)' && has "$W" 'krok 2/8: Z którego hosta?'; then
    ok "kreator: Enter na hoscie z relacja odmawia i mowi dlaczego (relacja = para hostow; modyfikacji CLI nie umie)"
else
    bad "kreator: host z relacja" "$W"
fi
W="$(wiz ins,enter,down,enter --width 110)"
if has "$W" '> Adres hosta                    _' && has "$W" 'po Enterze kreator sprawdzi SSH, ZFS i pakiet'; then
    ok "kreator: 'inny host' = jedno pole na adres"
else
    bad "kreator: inny host" "$W"
fi
# DIAGNOZA: trzy fakty z check-source, jedna akcja.
H="ins,enter,down,enter,text:192.168.28.98,enter"
W="$(wizn "$H" --width 110)"
if has "$W" 'krok 2/8: Sprawdzam host' && has "$W" '192.168.28.98   (pve9b)' && has "$W" 'SSH jako root .............. OK   klucz roota pve10 jest tam zaufany' \
        && has "$W" 'ZFS ........................ OK   hdd 39.5G (wolne 39.5G)' && has "$W" 'pakiet zfs-snapshot-all .... BRAK /root/scripts/zsa-none nie istnieje' \
        && has "$W" '> Zainstaluj pakiet na 192.168.28.98  (prepare-source: git clone jako root; bez crona, bez relacji)' && has "$W" '  Wróć'; then
    ok "kreator: diagnoza hosta bez pakietu -- SSH OK, ZFS OK z pula, pakiet BRAK, akcja 'Zainstaluj pakiet' i 'Wroc'"
else
    bad "kreator: diagnoza bez pakietu" "$W"
fi
W="$(wizn "$H,enter" --width 110)"
if has "$W" 'POTWIERDZENIE: Zainstaluj pakiet na 192.168.28.98' && has "$W" 'prepare-source' && has "$W" '192.168.28.98 --yes' && has "$W" 'bez crona' && [ ! -s "$XL" ]; then
    ok "kreator: 'Zainstaluj pakiet' pokazuje komende prepare-source HOST --yes do potwierdzenia; nic nie wykonano"
else
    bad "kreator: potwierdzenie prepare-source" "$W"
fi
W="$(wizn "$H,enter,t" --width 110)"
if grep -q "prepare-source 192.168.28.98 --yes$" "$XL" && [ "$(grep -c . "$XL")" -eq 1 ] && has "$W" 'WYJŚCIE: Instalacja pakietu na 192.168.28.98'; then
    ok "kreator: 't' wykonuje DOKLADNIE prepare-source HOST --yes i otwiera okno wyjscia"
else
    bad "kreator: t prepare-source" "$(cat "$XL")" "$W"
fi
W="$(wizn "$H,enter,t,esc" --width 110)"
if has "$W" 'krok 2/8: Sprawdzam host'; then
    ok "kreator: Esc z okna wyjscia wraca do diagnozy (liczonej od nowa)"
else
    bad "kreator: powrot z instalacji" "$W"
fi
W="$(wiz "$H" --width 110)"
if has "$W" 'pakiet zfs-snapshot-all .... OK   /root/scripts/zfs-snapshot-all (rev' && has "$W" '> Dalej: lista datasetów na 192.168.28.98'; then
    ok "kreator: diagnoza hosta z pakietem -- OK z rewizja, jedna akcja 'Dalej: lista datasetow'"
else
    bad "kreator: diagnoza z pakietem" "$W"
fi
WD="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --wizard curses --exec-log "$XL" --screen relacje --keys "$H" --width 110 2>&1)"
if has "$WD" 'check-source nie odpowiedział: tryb offline' && has "$WD" '> Wróć (check-source nie odpowiedział'; then
    ok "kreator: gdy check-source nie odpowiada (tu: offline), diagnoza mowi to zdaniem i zostaje tylko 'Wroc'"
else
    bad "kreator: check-source offline" "$WD"
fi
# DATASETY: drzewo, wiele, rekurencja, filtr.
D="$H,enter"
W="$(wiz "$D" --width 110 --height 34)"
if has "$W" 'krok 2/8: Które datasety?' && has "$W" '> Dalej z zaznaczonymi (0)' && has "$W" 'Podrzędne zaznaczonego rodzica: -R  każdy osobnym strumieniem (flat), wyłączenia ✗ dozwolone -- zalecane' \
        && hasE "$W" '^║     hdd +33.2M  filesystem  \+16 podrzędne' && hasE "$W" '^║       data +9.1M  filesystem  \+3 podrzędne' && hasE "$W" '^║         photos +3.0M  filesystem' \
        && hasE "$W" '^║         vm-201-disk-0 +12.0K  volume'; then
    ok "kreator: lista datasetow peera jako DRZEWO (wciecie, ostatni czlon, zajete, typ, liczba podrzednych), z linia rekurencji na gorze"
else
    bad "kreator: drzewo datasetow" "$W"
fi
W="$(wiz "$D,enter" --width 110 --height 34)"
if has "$W" '! zaznacz co najmniej jeden dataset' && has "$W" 'Które datasety?'; then
    ok "kreator: 'Dalej' bez zaznaczenia odmawia"
else
    bad "kreator: dalej bez zaznaczenia" "$W"
fi
SEL="$D,down,down,down,down,down,down,enter,down,down,down,down,down,down,enter,home"
W="$(wiz "$SEL" --width 110 --height 34)"
if has "$W" '> Dalej z zaznaczonymi (2)' && hasE "$W" '^║   ✓   data +9.1M' && hasE "$W" '^║   ·     docs +3.0M  filesystem  \(w rodzicu; Enter = wyłącz\)' && hasE "$W" '^║   ✓   home +6.1M'; then
    ok "kreator: Enter zaznacza (✓), podrzedne zaznaczonego rodzica sa '· (w rodzicu)', licznik w pierwszej linii"
else
    bad "kreator: zaznaczanie" "$W"
fi
W="$(wiz "$SEL,down,down,down,down,down,down,down,enter" --width 110 --height 34)"
if hasE "$W" '^║ . ✗     docs +3.0M  filesystem  \(wyłączony -X\)' && has "$W" 'Dalej z zaznaczonymi (2, wyłączone 1)'; then
    ok "kreator: Enter na podrzednym zaznaczonego rodzica WYLACZA go (✗, -X), licznik mowi ile wylaczonych"
else
    bad "kreator: wylaczenie podrzednego" "$W"
fi
W="$(wiz "$SEL,down,down,down,down,down,down,down,enter,up,up,up,up,up,up,enter" --width 110 --height 34)"
if has "$W" '! -r (atomic) nie ma czego filtrować: najpierw cofnij wyłączenia (hdd/data/docs)'; then
    ok "kreator: z wylaczeniem przelaczenie na -r odmawia (silnik odmawia -X pod -r)"
else
    bad "kreator: -r z wylaczeniami" "$W"
fi
W="$(wiz "$SEL,down,enter,down,down,down,down,down,down,enter" --width 110 --height 34)"
if has "$W" '! pod -r (atomic) nie da się wyłączyć podrzędnego -- przełącz na -R'; then
    ok "kreator: pod -r Enter na podrzednym odmawia i mowi, ze trzeba -R"
else
    bad "kreator: wylaczenie pod -r" "$W"
fi
W="$(wiz "$SEL,down,enter" --width 110 --height 34)"
if has "$W" 'Podrzędne zaznaczonego rodzica: -r  jeden strumień (atomic): bez wyłączeń, bez retencji u źródła'; then
    ok "kreator: linia rekurencji przelacza flat <-> atomic"
else
    bad "kreator: rekurencja" "$W"
fi
W="$(wiz "$D,text:home" --width 110 --height 34)"
if hasE "$W" '^║       home +6.1M' && hasE "$W" '^║         adam' && ! hasE "$W" '^║       data ' && has "$W" 'filtr: home_'; then
    ok "kreator: pisanie filtruje drzewo (home, adam, ewa), 'Dalej' i rekurencja zostaja"
else
    bad "kreator: filtr" "$W"
fi
# DOKAD: lista lokalna, ladowisko dla PODSWIETLONEGO celu nad lista.
T="$SEL,enter"
W="$(wiz "$T,down" --width 110 --height 34)"
if has "$W" 'krok 3/8: Dokąd trafi kopia?' && has "$W" 'skąd: 192.168.28.98 (hdd/data, hdd/home)' && has "$W" 'kopie wylądują w: hdd/backups/192.168.28.98/hdd/data' \
        && has "$W" '                  hdd/backups/192.168.28.98/hdd/home' && has "$W" '> hdd/backups '; then
    ok "kreator: krok 2 -- lista lokalnych datasetow, ladowisko kazdego zaznaczonego dla PODSWIETLONEGO celu, zanim padnie Enter"
else
    bad "kreator: dokad" "$W"
fi
# SZABLON slowami, Ins = nowy szablon (formularz z krokow b), Esc wraca do kreatora.
P="$T,down,enter"
W="$(wiz "$P" --width 120 --height 34)"
if has "$W" 'krok 4/8: Jak często i ile trzymać?' && has "$W" 'dokąd: hdd/backups' && has "$W" '> default          co godzinę (:01) · trzyma 24 godz., 7 dni, 4 tyg., 12 mies. · drabina GFS' \
        && has "$W" 'jedna rodzina · bez zamrażania · monitor 90m / 150m · godzinowy create' && has "$W" 'Ins = nowy szablon'; then
    ok "kreator: krok 3 -- lista szablonow SLOWAMI z kursorem na 'default', opis pod podswietlonym, Ins = nowy szablon"
else
    bad "kreator: szablony" "$W"
fi
W="$(wiz "$P,ins" --width 120 --height 40)"
if has "$W" '╔═ Nowy szablon na bazie: default ═' && has "$W" 'trzymaj godz.                24'; then
    ok "kreator: Ins na szablonie otwiera formularz nowego szablonu z pol bazy"
else
    bad "kreator: Ins nowy szablon" "$W"
fi
W="$(wiz "$P,ins,esc" --width 120 --height 34)"
if has "$W" 'krok 4/8' && has "$W" '> default '; then
    ok "kreator: Esc z formularza szablonu wraca do kroku 3"
else
    bad "kreator: Esc z szablonu" "$W"
fi
NP2="$P,ins,text:moj-h48,down,down,down,down,space,down,bs,bs,text:48,end,enter,t,esc"
W="$(wiz "$NP2" --width 120 --height 34)"
if grep -q "save-profile --from=default --as=moj-h48" "$XL" && has "$W" 'krok 4/8' && has "$W" '> moj-h48          (zapisany przed chwilą albo wpisany ręcznie; czasownik sprawdzi)'; then
    ok "kreator: zapis nowego szablonu (t) i Esc wraca do kroku 3 z NOWYM szablonem na gorze listy, podswietlonym"
else
    bad "kreator: nowy szablon z kreatora" "$(cat "$XL")" "$W"
fi
# NAZWA, KONTO, ZAAWANSOWANE.
N="$P,enter"
W="$(wiz "$N" --width 110)"
if has "$W" 'krok 5/8: Jak nazwać relację?' && has "$W" 'szablon: default' && has "$W" '> Nazwa relacji                  pve9b_' && has "$W" 'relacja jest hosta, nie datasetu'; then
    ok "kreator: krok 4 -- nazwa zaproponowana z nazwy HOSTA (pve9b), bo relacja jest hosta"
else
    bad "kreator: nazwa" "$W"
fi
A="$N,enter"
W="$(wiz "$A" --width 130)"
if has "$W" 'krok 6/8: Kto ma uruchamiać kopie?' && has "$W" 'nazwa: pve9b' && has "$W" '  root -- bez izolacji' && has "$W" '> zfsbackup -- konto delegowane (zostanie utworzone, dostanie zfs allow)' && has "$W" '  inne konto -- podasz nazwę'; then
    ok "kreator: krok 5 -- trzy linie konta, kursor na zfsbackup (domyslne konto delegowane)"
else
    bad "kreator: konto" "$W"
fi
W="$(wiz "$A,down,enter,enter" --width 110)"
if has "$W" '! podaj nazwę konta' && has "$W" 'Nazwa konta'; then
    ok "kreator: 'inne konto' bez nazwy nie idzie dalej"
else
    bad "kreator: inne bez nazwy" "$W"
fi
W="$(wiz "$A,down,enter,text:ops,enter" --width 130)"
if has "$W" 'krok 7/8' && has "$W" 'konto: ops'; then
    ok "kreator: 'inne konto' + nazwa idzie dalej, naglowek pokazuje konto: ops"
else
    bad "kreator: inne konto" "$W"
fi
Z="$A,enter"
W="$(wiz "$Z" --width 110)"
if has "$W" 'krok 7/8: Zaawansowane (zwykle bez zmian)' && has "$W" '> Bez zmian, dalej' && has "$W" 'Port SSH peera                 22' && has "$W" 'Retencja u źródła              taka sama jak tutaj (default)' \
        && has "$W" 'Uprawnienia na peerze          nadaj zdalnie: nie' && has "$W" 'Parowanie                      przez ssh (automatyczne)' && has "$W" 'Podrzędne datasety             -R  każdy osobno (flat)' \
        && has "$W" 'Pomijaj migawki o nazwach od…  __replicate_,vzdump,__migration__'; then
    ok "kreator: krok 6 -- lista ustawien z wartosciami, 'Bez zmian, dalej' na gorze, w tym pomijanie migawek po masce z DOMYSLNYMI maskami Proxmoxa"
else
    bad "kreator: zaawansowane" "$W"
fi
W="$(wiz "$Z,down,enter,bs,bs,text:2222,enter,down,down,enter,down,enter" --width 110)"
if has "$W" 'Port SSH peera                 2222' && has "$W" 'nadaj zdalnie: tak' && has "$W" 'ręczne: pakiet do przeniesienia'; then
    ok "kreator: Enter na ustawieniu zmienia je (port pisany, przelaczniki przelaczane)"
else
    bad "kreator: edycja zaawansowanych" "$W"
fi
# POMIJANIE MIGAWEK PO MASCE (wlasciciel 2026-09-16): --exclude-family=A,B, silnik -E
BS34="$(printf 'bs,%.0s' $(seq 34))"
W="$(wiz "$Z,end,enter" --width 130)"
if has "$W" '> Pomijaj migawki o nazwach od…  __replicate_,vzdump,__migration___' && has "$W" 'domyślnie migawki Proxmoxa (replikacja pvesr, vzdump, migracja). Puste = kopiuj wszystkie'; then
    ok "kreator: Enter na 'Pomijaj migawki' otwiera pole z domyslnymi maskami Proxmoxa do edycji i wyjasnieniem"
else
    bad "kreator: pole pomijania migawek" "$W"
fi
W="$(wiz "$Z,end,enter,${BS34}text:pvesr_ ,enter" --width 130)"
if has "$W" 'Pomijaj migawki o nazwach od…  pvesr_ ' && ! has "$W" 'pvesr_ _' && has "$W" 'krok 7/8'; then
    ok "kreator: wpisana maska wraca do ustawien oczyszczona ze spacji (przecinka nie da sie wpisac przez --keys)"
else
    bad "kreator: lista pomijania" "$W"
fi
W="$(wiz "$Z,end,enter,${BS34}text:pvesr_,enter,home,enter" --width 130 --height 34)"
if has "$W" 'Migawki o nazwach od „pvesr_…” nie będą kopiowane.' && has "$W" '--exclude-family=pvesr_'; then
    ok "kreator: podsumowanie mowi zdaniem, ktore migawki sa pomijane, a komenda ma --exclude-family"
else
    bad "kreator: podsumowanie pomijania" "$W"
fi
W="$(wiz "$Z,end,enter,${BS34}text:pvesr_,enter,home,enter,down,enter,t" --width 130 --height 34)"
if grep -q -- "--name=pve9b --exclude-family=pvesr_ --local-user=zfsbackup --install --yes$" "$XL"; then
    ok "kreator: 't' wykonuje komende z --exclude-family=pvesr_"
else
    bad "kreator: exclude-family argv" "$(cat "$XL")"
fi
W="$(wiz "$Z,end,enter,${BS34}enter,home,enter,down,enter,t" --width 130 --height 34)"
if ! grep -q -- "--exclude-family" "$XL" && grep -q -- "--install --yes$" "$XL"; then
    ok "kreator: puste pole = kopiuj wszystkie migawki, bez --exclude-family w komendzie"
else
    bad "kreator: puste maski" "$(cat "$XL")"
fi
W="$(wiz "$Z,down,down,enter" --width 120)"
if has "$W" '╔═ Retencja u źródła (Esc = taka sama jak tutaj) ═' && has "$W" '  d7h24            co godzinę'; then
    ok "kreator: 'Retencja u zrodla' otwiera liste szablonow slowami"
else
    bad "kreator: retencja u zrodla" "$W"
fi
# PODSUMOWANIE: zdanie + komenda; plan; Wykonaj -> potwierdzenie -> t.
S7="$Z,enter"
W="$(wiz "$S7" --width 110 --height 34)"
if has "$W" 'Migawki o nazwach od „__replicate_…” i „vzdump…” i „__migration__…” nie będą kopiowane.' && has "$W" 'krok 8/8: Podsumowanie' && has "$W" 'Co godzinę (:01) pve10 pobierze migawki 2 datasetów (hdd/data, hdd/home) z hosta 192.168.28.98 do' \
        && has "$W" 'hdd/backups/192.168.28.98/…, trzymając 24 godz., 7 dni, 4 tyg., 12 mies. (drabina GFS, jedna rodzina).' \
        && has "$W" 'Bez zamrażania. Monitor: 90m / 150m.' && has "$W" 'Relacja: pve9b. Zadania na pve10 jako zfsbackup. Na peerze konto zfsbackup-pve10 (tworzy JOIN).' \
        && has "$W" 'Komenda:' && has "$W" '--source=192.168.28.98:hdd/data,hdd/home' && has "$W" '--name=pve9b' && has "$W" '--local-user=zfsbackup' \
        && has "$W" '> Pokaż plan  (czasownik bez --install: nic nie zmienia)' && has "$W" '  Wykonaj  (plan, potem komenda z --install --yes' && [ ! -s "$XL" ]; then
    ok "kreator: krok 7 -- ZDANIEM (kadencja, ile datasetow i ktore, host, ladowisko, retencja, monitor, konto, peer) + komenda z lista datasetow; nic nie wykonano"
else
    bad "kreator: podsumowanie" "$W" "$(cat "$XL")"
fi
W="$(wiz "$S7,enter" --width 110 --height 34)"
if has "$W" 'WYJŚCIE: Plan (read-only, bez --install) -- Esc wraca do kreatora' && has "$W" '[atrapa] plan:' && ! has "$W" '--install --yes' && [ ! -s "$XL" ]; then
    ok "kreator: 'Pokaz plan' = czasownik bez --install w oknie; nic nie wykonano"
else
    bad "kreator: plan" "$W"
fi
W="$(wiz "$S7,enter,esc" --width 110 --height 34)"
if has "$W" 'krok 8/8: Podsumowanie'; then
    ok "kreator: Esc z planu wraca do podsumowania"
else
    bad "kreator: powrot z planu" "$W"
fi
W="$(wiz "$S7,down,enter" --width 110 --height 34)"
if has "$W" 'POTWIERDZENIE: Nowa relacja pve9b z 192.168.28.98' && has "$W" '--source=192.168.28.98:hdd/data,hdd/home --target=hdd/backups' && has "$W" '--install --yes' && has "$W" 'Plan czasownika (read-only, bez --install)' && [ ! -s "$XL" ]; then
    ok "kreator: 'Wykonaj' = plan + potwierdzenie z pelna komenda; nic przed t"
else
    bad "kreator: wykonaj" "$W" "$(cat "$XL")"
fi
W="$(wiz "$S7,down,enter,t" --width 110 --height 34)"
if grep -q -- "--source=192.168.28.98:hdd/data,hdd/home --target=hdd/backups --profile=default --name=pve9b --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --install --yes$" "$XL" && has "$W" 'WYJŚCIE: Nowa relacja pve9b'; then
    ok "kreator: 't' wykonuje DOKLADNIE pokazana komende (lista datasetow po przecinku, konto z listy) i otwiera okno wyjscia"
else
    bad "kreator: t" "$(cat "$XL")" "$W"
fi
# root z listy = bez --local-user; atomic, port, retencja, przelaczniki pod flagami
W="$(wiz "$A,up,enter,down,enter,bs,bs,text:2222,enter,down,enter,home,enter,down,enter,down,enter,down,enter,home,enter,down,enter,t" --width 110 --height 34)"
if grep -q -- "--source=192.168.28.98:2222:hdd/data,hdd/home --target=hdd/backups --profile=default --source-profile=Y5M12D31H24 --name=pve9b --recursive=atomic --exclude-family=__replicate_,vzdump,__migration__ --grant-remotely --manual-join --install --yes$" "$XL"; then
    ok "kreator: root = bez --local-user; port w HOST:PORT, retencja u zrodla, atomic, oba przelaczniki -- kazde pod swoja flaga"
else
    bad "kreator: pelne argv" "$(cat "$XL")"
fi
# SYNCHRO: bez kroku 'Dokad', komenda z --mode=sync, zdanie o obu stronach
SY="ins,down,enter,down,enter,text:192.168.28.98,enter,enter,down,down,down,down,down,down,enter,home,enter"
W="$(wiz "$SY" --width 120 --height 34)"
if has "$W" 'krok 4/8: Jak często i ile trzymać?' && has "$W" 'typ: synchro   skąd: 192.168.28.98 (hdd/data)' && ! has "$W" 'dokąd:'; then
    ok "kreator: synchro pomija krok 'Dokad' (mapowanie to tozsamosc) i idzie z datasetow do szablonu"
else
    bad "kreator: synchro bez celu" "$W"
fi
W="$(wiz "$SY,enter,enter,enter,enter" --width 120 --height 34)"
if has "$W" 'krok 8/8: Podsumowanie' && has "$W" 'pve10 i 192.168.28.98 będą trzymać migawki datasetu hdd/data pod tą samą ścieżką po obu stronach' && has "$W" '--source=192.168.28.98:hdd/data --mode=sync' && ! has "$W" '--target='; then
    ok "kreator: synchro -- zdanie o obu stronach i komenda --mode=sync bez --target"
else
    bad "kreator: synchro podsumowanie" "$W"
fi
W="$(wiz "$SY,enter,enter,enter,enter,down,enter,t" --width 120 --height 34)"
if grep -q -- "--source=192.168.28.98:hdd/data --mode=sync --profile=default --name=pve9b --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --install --yes$" "$XL"; then
    ok "kreator: synchro 't' wykonuje forme jednokomendowa z --mode=sync"
else
    bad "kreator: synchro argv" "$(cat "$XL")"
fi
W="$(wiz "$SY,esc" --width 120 --height 34)"
if has "$W" 'krok 2/8: Które datasety?'; then
    ok "kreator: synchro Esc z szablonu wraca do datasetow (bez 'Dokad')"
else
    bad "kreator: synchro Esc" "$W"
fi
# WYLACZENIA W ARGV
W="$(wiz "$SEL,down,down,down,down,down,down,down,enter,home,enter,down,enter,enter,enter,enter,enter,down,enter,t" --width 110 --height 34)"
if grep -q -- "--source=192.168.28.98:hdd/data,hdd/home --target=hdd/backups --profile=default --name=pve9b --exclude-child=hdd/data/docs --exclude-family=__replicate_,vzdump,__migration__ --local-user=zfsbackup --install --yes$" "$XL"; then
    ok "kreator: wylaczony podrzedny idzie do argv jako --exclude-child=<dataset>"
else
    bad "kreator: exclude-child argv" "$(cat "$XL")"
fi
# ESC = krok wstecz z zachowaniem odpowiedzi; Esc w kroku 1 = anuluj
W="$(wiz "$P,esc" --width 110 --height 34)"
if has "$W" 'krok 3/8' && has "$W" 'skąd: 192.168.28.98 (hdd/data, hdd/home)'; then
    ok "kreator: Esc = krok wstecz, odpowiedzi zostaja"
else
    bad "kreator: Esc wstecz" "$W"
fi
W="$(wiz ins,esc --width 110)"
if has "$W" 'anulowano -- nic nie wykonano' && ! has "$W" 'Nowa relacja' && [ ! -s "$XL" ]; then
    ok "kreator: Esc w kroku 1 zamyka kreator bez sladu"
else
    bad "kreator: Esc" "$W"
fi
WE="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$FIX/nie-ma.json" --datasets-remote "$P10/list-datasets-pve9b.json" --datasets-local "$P10/list-datasets.json" --check-source "$P10/check-source-pkg.json" --wizard curses --exec-log "$XL" --screen relacje --keys "$T,down,enter" --width 110 2>&1)"
if has "$WE" 'list-profiles: błąd źródła' && has "$WE" 'wpisz nazwę szablonu ręcznie' && has "$WE" 'krok 4/8'; then
    ok "kreator: zepsute list-profiles nie blokuje kreatora -- krok 3 ma linie 'wpisz nazwe recznie'"
else
    bad "kreator: blad list-profiles" "$WE"
fi
# szerokosci okien kreatora
wz_ok=1
for w in 80 120 200; do
    for keys in ins "$H" "$D" "$P" "$S7" "$S7,down,enter"; do
        out="$(wiz "$keys" --width "$w")"
        n="$(printf '%s\n' "$out" | "$PY" -c "import sys; ls=sys.stdin.read().split('\n')[:-1]; print(sum(1 for l in ls if len(l)!=$w), len(ls))")"
        case "$n" in "0 24") ;; *) wz_ok=0; echo "  kreator w=$w keys=$keys -> $n" ;; esac
    done
done
if [ "$wz_ok" -eq 1 ]; then
    ok "kreator: kazdy krok, diagnoza, drzewo, podsumowanie i potwierdzenie maja dokladnie szerokosc terminala (80/120/200)"
else
    bad "kreator: szerokosci"
fi

if has "$S" 'Enter F4:pauza Del F7:eksport F8:import Ins'; then
    ok "akcje: stopka ramki F3 wymienia klawisze akcji przy 80 kolumnach"
else
    bad "akcje: stopka" "$S"
fi
# szerokosc: okna akcji tez trzymaja kontrakt
aw_ok=1
for w in 80 120 200; do
    for keys in down,F4 down,del down,F7 down,F4,t; do
        out="$(HOME=/root act "$keys" --width "$w")"
        n="$(printf '%s\n' "$out" | "$PY" -c "import sys; ls=sys.stdin.read().split('\n')[:-1]; print(sum(1 for l in ls if len(l)!=$w), len(ls))")"
        case "$n" in "0 24") ;; *) aw_ok=0; echo "  akcje w=$w keys=$keys -> $n" ;; esac
    done
done
if [ "$aw_ok" -eq 1 ]; then
    ok "akcje: okna potwierdzenia, pola i wyjscia maja dokladnie szerokosc terminala (80/120/200)"
else
    bad "akcje: szerokosci okien"
fi
rm -f "$XL"

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
printf '%s' "$out" | tr '|' '\n' >&2
exit "$rc"
EOF
cat > "$NR/bin/zb" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${NR_DIR:?}/zb.log"
case "$1" in
    status)         cat "$NR_FIX/status.json" ;;
    check-source)   if [ -e "$NR_DIR/installed" ]; then cat "$NR_FIX/check-source-pkg.json"; else cat "$NR_FIX/${NR_CHECK:-check-source-pkg.json}"; fi ;;
    list-datasets)  if [ "$2" = "--json" ]; then cat "$NR_FIX/list-datasets.json"; else cat "$NR_FIX/list-datasets-pve9b.json"; fi ;;
    list-profiles)  cat "$NR_FIX/list-profiles.json" ;;
    --source=*)     case " $* " in *" --install "*) echo ">>> atrapa: zainstalowano"; exit "${NR_INSTALL_RC:-0}" ;; *) echo "RUX plan (atrapa)"; exit "${NR_PLAN_RC:-0}" ;; esac ;;
    prepare-source) : > "$NR_DIR/installed"; echo "prepared" ;;
    *)              echo "atrapa zb: nieznany czasownik $1" >&2; exit 9 ;;
esac
EOF
chmod +x "$NR/bin/whiptail" "$NR/bin/zb"
nr_run() {   # <plik odpowiedzi jako tekst> [ENV=...] -> stdout kreatora; dzienniki w $NR
    rm -f "$NR/wt.log" "$NR/wt.n" "$NR/zb.log" "$NR/installed"
    printf '%s' "$1" > "$NR/answers"; shift
    ( export NR_DIR="$NR" NR_FIX="$P10" WHIPTAIL="$NR/bin/whiptail" ZFS_BACKUP="$NR/bin/zb" PYTHON="$PY" "$@"; bash "$NRS" ) 2>"$NR/err" </dev/null
    local rc=$?
    grep -- ' --install --yes$' "$NR/zb.log" 2>/dev/null | sed 's/^/CMD: /; s/$/ /'
    return "$rc"
}
T=$'\t'
# Kroki 5-10 z domyslnymi odpowiedziami: cel, szablon, nazwa, konto, 'bez zmian', plan, WYKONAJ
NRT="0${T}hdd/backups
0${T}default
0${T}pve9b
0${T}root
0${T}go
0${T}
0${T}
"
NRTS="0${T}default
0${T}pve9b
0${T}root
0${T}go
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
