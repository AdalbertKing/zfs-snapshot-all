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
ALL="--status $P10/status.json --jobs $P10/list-jobs.json --monitors $P10/monitor.json --progress $P10/progress.json --replicas $P10/replicas.json --config $P10/show-config.json"
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
if hasE "$S" '^║ lab-ct201 +pve10<192.168.28.99 +active +aktualne +[0-9]{2}:30 +║'; then
    ok "relacje: jeden wiersz na RELACJE -- nazwa, KIERUNEK (ten host po lewej), stan z rekordu, kopie z monitora, nastepny bieg z harmonogramu"
else
    bad "relacje: wiersz relacji sklejony z czterech czytelnikow" "$S"
fi
if has "$S" 'Ostatni bieg brak zapisu w historii'; then
    ok "relacje: ostatni wynik zszedl do panelu (kolumne zajal kierunek)"
else
    bad "relacje: ostatni wynik w panelu" "$S"
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
if hasE "$S" '^║ duplikat +pve10[?]192.168.28.99 +seeding +-- +seed duplikat +║'; then
    ok "relacje: relacja nieaktywna pokazuje NASTEPNY KROK CLI (seed duplikat), nie godzine z crona"
else
    bad "relacje: nastepny krok dla relacji w zasiewie" "$S"
fi
# Rekord usuniety jest faktem, ale nie robota: jest, i jest OSTATNI.
if [ "$(printf '%s\n' "$S" | grep -n '192.168.28.99 *removed' | cut -d: -f1)" -gt "$(printf '%s\n' "$S" | grep -n '^║ lab-vm101' | cut -d: -f1)" ] 2>/dev/null; then
    ok "relacje: rekord 'removed' jest widoczny i stoi na koncu listy"
else
    bad "relacje: rekord removed" "$S"
fi
# Panel pod lista przy 80 kolumnach: pierwszy wiersz (duplikat) ma focus.
if has "$S" 'duplikat -- szczegóły' && has "$S" 'Źródła (1)   hdd/lab/vm-101' && has "$S" "NIE znaczy 'bez awarii'"; then
    ok "relacje: panel szczegolow pod lista mowi o wierszu z focusem i tlumaczy brak historii"
else
    bad "relacje: panel szczegolow" "$S"
fi
S4="$(screen relacje down,down,down,down)"
if has "$S4" 'lab-vm101 -- szczegóły' && hasE "$S4" 'Następny +2026-09-09 [0-9]{2}:24:00  \(wg crontaba, 24 \* \* \* \*\)'; then
    ok "relacje: kursor przesuwa panel; nastepny bieg policzony z harmonogramu 24 * * * *"
else
    bad "relacje: kursor i nastepny bieg" "$S4"
fi
if has "$S4" 'Kopie        aktualne   progi 90m / 150m'; then
    ok "relacje: panel nazywa progi monitora przy werdykcie"
else
    bad "relacje: progi w panelu" "$S4"
fi

# --- PAUZA: prawdziwy stan z pause-client na pve10 -------------------------
SP="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $PAUSED --screen relacje --keys down,down,down 2>&1)"
if hasE "$SP" '^║ lab-srv-b +pve10<192.168.28.99 +active PAUZA +aktualne +-- pauza -- +║'; then
    ok "relacje: relacja wstrzymana ma PAUZA w stanie i '-- pauza --' zamiast nastepnego biegu"
else
    bad "relacje: wiersz pauzy" "$SP"
fi
if has "$SP" 'Uwaga        relacja wstrzymana (pause-client)'; then
    ok "relacje: ...a panel mowi, ze starzenie kopii jest tu oczekiwane"
else
    bad "relacje: uwaga o pauzie w panelu" "$SP"
fi

# --- ZADANIA BEZ REKORDU RELACJI (hostA: push/local/pull, WARNING/CRITICAL) --
H="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen relacje 2>&1)"
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
U="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/unreadable.json" --monitors "$FIX/monitors.json" --screen relacje 2>&1)"
if hasE "$U" 'konto backupacct +[?] +nieczytelny +nie odpowiada'; then
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
if hasE "$Z" '^║ lab-vm101 +pve10<192.168.28.99 +wysyłka hourly +….*/lab/vm-101 +aktualne +║'; then
    ok "zadania: wysylka pobrania = 'pve10<peer' (ten host po lewej), rodzina bez automated_, zakres ciety od lewej, werdykt slowem"
else
    bad "zadania: wiersz wysylki" "$Z"
fi
if hasE "$Z" '^║ lab-vm101 +local +porządki -H24 +'; then
    ok "zadania: porzadki na ladowisku = 'local' i to, co trzymaja (-H24)"
else
    bad "zadania: wiersz porzadkow" "$Z"
fi
if [ "$(printf '%s\n' "$Z" | grep -cE '^║ lab-vm101 +pve10<192.168.28.99 +porządki -H24 ')" -eq 1 ] && [ "$(printf '%s\n' "$Z" | grep -cE '^║ lab-vm101 +local +porządki -H24 ')" -eq 1 ]; then
    ok "zadania: porzadki na ZDALNYM zrodle niosa kierunek relacji, nie 'local'"
else
    bad "zadania: zdalne porzadki" "$Z"
fi
Z120="$(screen zadania "" --width 120)"
if has "$Z120" 'Harmonogram' && ! has "$Z" 'Harmonogram'; then
    ok "zadania: harmonogram jest kolumna od 100 kolumn, przy 80 zostaje w panelu"
else
    bad "zadania: kolumna harmonogramu" "$Z" "$Z120"
fi
if has "$Z" 'harmonogram 24 * * * *'; then
    ok "zadania: ...i w panelu jest przy 80"
else
    bad "zadania: harmonogram w panelu" "$Z"
fi
ZH="$("$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --screen zadania 2>&1)"
if hasE "$ZH" '^║ pve9 +hostA>pve9 +wysyłka hourly' && hasE "$ZH" '^║ pve1 +hostA<pve1 +wysyłka hourly' && hasE "$ZH" '^║ \(bez rel\.\) +local +wysyłka daily'; then
    ok "zadania: wysylka = 'hostA>pve9', pobranie = 'hostA<pve1', kopia na hoscie = 'local'; zadanie bez etykiety mowi '(bez rel.)'"
else
    bad "zadania: trzy kierunki na hostA" "$ZH"
fi
ZE="$(screen zadania down,enter)"
if has "$ZE" '╔═ lab-vm101 ═' && has "$ZE" 'szczebel keep_hourly  (sekcja prune)' && has "$ZE" 'kierunek local'; then
    ok "zadania: Enter otwiera szczegoly zadania -- szczebel, sekcja, kierunek, harmonogram"
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
AH="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F4 2>&1)"
"$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" --exec-log "$XL" --screen relacje --keys F4,t >/dev/null 2>&1
if [ ! -s "$XL" ] && has "$AH" 'to nie jest relacja (zadanie bez rekordu)'; then
    ok "akcje: na zadaniu BEZ rekordu (ksztalt produkcji) akcja odmawia -- nie ma czego pauzowac czasownikiem"
else
    bad "akcje: bez rekordu odmawia" "$(cat "$XL")" "$AH"
fi
A="$(act down,ins)"
if has "$A" '╔═ Nowa relacja (forma jednokomandowa) ═' || has "$A" '╔═ Nowa relacja (forma jednokomendowa) ═' && [ ! -s "$XL" ]; then
    ok "akcje: Ins otwiera kreator nowej relacji, nic nie wykonujac"
else
    bad "akcje: Ins" "$A"
fi
# ============================================================================
# KREATOR NOWEJ RELACJI (Ins) -- forma jednokomendowa, szablon z listy, PLAN
# ============================================================================
# Wlasciciel: "Tworzenie/modyfikacja relacji to z kolei ekran pozwalajacy na
# wybraniu gotowego template" i "przypominam o podgladzie komendy bash".
# Kolejnosc: pola -> [ PLAN ] (czasownik bez --install, read-only) -> pelna
# komenda z --install --yes -> 't'. Fikstura szablonow to doslowne wyjscie
# `list-profiles --json --no-render` z pve10 (16 profili, 0,8 s).
wiz() {   # <keys> [extra] -> ekran; dziennik w $XL
    : > "$XL"
    "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$P10/list-profiles.json" --exec-log "$XL" --screen relacje --keys "$1" "${@:2}" 2>&1
}
W="$(wiz ins)"
if has "$W" '╔═ Nowa relacja (forma jednokomendowa) ═' && has "$W" '> Źródło HOST:DATASET    _' && has "$W" 'Profil (szablon)       default' \
        && has "$W" '[ PLAN ]' && has "$W" 'szablonów do wyboru: 16'; then
    ok "kreator: Ins otwiera formularz w kolejnosci formy jednokomendowej, profil domyslnie 'default', 16 szablonow z list-profiles"
else
    bad "kreator: formularz" "$W"
fi
W="$(wiz ins,text:192.168.28.99:hdd/lab/x,enter,text:hdd/backups,enter,enter)"
if has "$W" '╔═ Szablon dla pola: Profil (szablon) ═' && hasE "$W" '^║ > default +gfs +one-family' && hasE "$W" '^║   d7h24 +flat +family-per-tier'; then
    ok "kreator: Enter na polu Profil otwiera liste szablonow (nazwa, mechanizm, ksztalt, opis), kursor na obecnym"
else
    bad "kreator: lista szablonow" "$W"
fi
W="$(wiz ins,text:192.168.28.99:hdd/lab/x,enter,text:hdd/backups,enter,enter,down,enter)"
if has "$W" 'Profil (szablon)       m12w4d7h24-age'; then
    ok "kreator: wybor z listy wraca do formularza z nowa wartoscia"
else
    bad "kreator: wybor szablonu" "$W"
fi
# PLAN: komenda bez --install (read-only) jest pokazana jako podglad, a do
# potwierdzenia idzie ta sama z --install --yes.
W="$(wiz ins,text:192.168.28.99:hdd/lab/x,enter,text:hdd/backups,enter,end,enter)"
if has "$W" 'POTWIERDZENIE: Nowa relacja: 192.168.28.99:hdd/lab/x -> hdd/backups' && has "$W" '--source=192.168.28.99:hdd/lab/x --target=hdd/backups' \
        && has "$W" '--profile=default --install --yes' && has "$W" '[atrapa] plan:' && has "$W" 'Plan czasownika (read-only, bez --install)'; then
    ok "kreator: [ PLAN ] pokazuje plan czasownika (bez --install) i pelna komende z --install --yes do potwierdzenia"
else
    bad "kreator: plan i potwierdzenie" "$W"
fi
if [ ! -s "$XL" ]; then
    ok "kreator: ...i do tego miejsca nic nie zostalo wykonane (plan w atrapie tez nie jest zapisem)"
else
    bad "kreator: nic przed t" "$(cat "$XL")"
fi
W="$(wiz ins,text:192.168.28.99:hdd/lab/x,enter,text:hdd/backups,enter,end,enter,t)"
if grep -q -- "--source=192.168.28.99:hdd/lab/x --target=hdd/backups --profile=default --install --yes$" "$XL" && has "$W" 'WYJŚCIE: Nowa relacja'; then
    ok "kreator: 't' wykonuje DOKLADNIE pokazana forme jednokomendowa z --install --yes i otwiera okno wyjscia"
else
    bad "kreator: t" "$(cat "$XL")" "$W"
fi
# kazde pole trafia do argv pod swoja flaga, przelaczniki jako gole flagi
W="$(wiz ins,text:h:d,enter,text:t,enter,down,text:nazwa,enter,text:2222,enter,text:d7h24,down,text:bak,enter,space,down,space,down,enter,t)"
if grep -q -- "--source=h:d --target=t --profile=default --source-profile=d7h24 --name=nazwa --port=2222 --local-user=bak --grant-remotely --manual-join --install --yes$" "$XL"; then
    ok "kreator: nazwa, port, profil zrodla, konto lokalne i oba przelaczniki ida do argv pod swoimi flagami, w kolejnosci formy"
else
    bad "kreator: pelne argv" "$(cat "$XL")"
fi
# ODMOWY: puste zrodlo/cel -- komunikat W formularzu, nic nie wykonane; Esc anuluje
W="$(wiz ins,end,enter)"
if has "$W" 'kreator: Źródło i Cel są wymagane' && has "$W" '╔═ Nowa relacja' && [ ! -s "$XL" ]; then
    ok "kreator: puste Zrodlo/Cel -- odmowa W formularzu (nie znika), nic nie wykonane"
else
    bad "kreator: puste pola" "$W"
fi
W="$(wiz ins,text:x:y,esc)"
if has "$W" 'anulowano -- nic nie wykonano' && ! has "$W" '╔═ Nowa relacja' && [ ! -s "$XL" ]; then
    ok "kreator: Esc zamyka formularz bez sladu"
else
    bad "kreator: Esc" "$W"
fi
W="$(wiz ins,text:h:d,enter,text:t,enter,enter,esc)"
if has "$W" 'Profil (szablon)       default' && has "$W" '╔═ Nowa relacja'; then
    ok "kreator: Esc na liscie szablonow wraca do formularza bez zmiany pola"
else
    bad "kreator: Esc na liscie" "$W"
fi
# bez zrodla szablonow (brak pliku): formularz nadal dziala, mowi o bledzie
WE="$(: > "$XL"; "$PY" "$TUI" --render-once --offline --utf8 --now "$NOW" $ALL --profiles "$FIX/nie-ma.json" --exec-log "$XL" --screen relacje --keys ins 2>&1)"
if has "$WE" 'list-profiles: błąd źródła' && has "$WE" 'wpisz nazwę szablonu ręcznie'; then
    ok "kreator: zepsute list-profiles nie blokuje kreatora -- mowi o bledzie i pozwala wpisac nazwe"
else
    bad "kreator: blad list-profiles" "$WE"
fi
# szerokosci okien kreatora
wz_ok=1
for w in 80 120 200; do
    for keys in ins "ins,text:a:b,enter,text:c,enter,enter" "ins,text:a:b,enter,text:c,enter,end,enter"; do
        out="$(wiz "$keys" --width "$w")"
        n="$(printf '%s\n' "$out" | "$PY" -c "import sys; ls=sys.stdin.read().split('\n')[:-1]; print(sum(1 for l in ls if len(l)!=$w), len(ls))")"
        case "$n" in "0 24") ;; *) wz_ok=0; echo "  kreator w=$w keys=$keys -> $n" ;; esac
    done
done
if [ "$wz_ok" -eq 1 ]; then
    ok "kreator: formularz, lista szablonow i potwierdzenie maja dokladnie szerokosc terminala (80/120/200)"
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
S120="$(screen relacje "" --width 120)"
if [ "$(printf '%s\n' "$S120" | grep -c '║.*│')" -gt 5 ] && [ "$(printf '%s\n' "$S" | grep -c '║.*│')" -eq 0 ]; then
    ok "wyglad: od 120 kolumn panel stoi OBOK listy, przy 80 pod nia"
else
    bad "wyglad: panel obok od 120" "$S120"
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
if hasE "$A" '^\| lab-ct201 +pve10<192.168.28.99 +active +aktualne' && has "$A" 'Zrodla (1)'; then
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
if has "$S" ' F1 Pomoc F2 Zadania [F3 Relacje] F4 Transfery F5 Monitor F6 Nośniki q Wyjście'; then
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

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
