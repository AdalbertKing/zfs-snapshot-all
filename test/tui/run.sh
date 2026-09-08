#!/bin/bash
# ============================================================================
# tui -- EKRAN 1, SPRAWDZONY BEZ TERMINALA
#
# Owner, 2026-09-08: "Rob ekran 1 TUI".
#
# Rysowanie jest funkcja czysta (STAN -> LINIE) i to nie jest estetyka: to
# jedyny sposob, w jaki ten ekran da sie sprawdzic. `plink -batch` nie daje
# terminala, wiec petli curses nie da sie uruchomic na hoscie z tej maszyny.
# `--render-once` drukuje DOKLADNIE to, co pokazalby ekran, wiec ta suita
# sprawdza to samo, co widzi operator.
#
# WEJSCIE POCHODZI Z PRAWDZIWYCH CZASOWNIKOW. Fikstury nie sa pisane recznie --
# powstaly przez uruchomienie `list-jobs --json` i `monitor --json` na
# przechwyconym bloku crona (test/realshape/captures/), wiec lancuch jest pelny:
# bajty z hosta -> czasownik -> ekran. Recznie napisany JSON zgadzalby sie z
# ekranem z definicji, co jest dokladnie ta wada, ktora suita realshape opisuje.
# ============================================================================
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIX="$REPO/test/tui/fixtures"
TUI="$REPO/tui/zfs-tui.py"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; shift; [ $# -gt 0 ] && printf '  %s\n' "$@"; }

# INTERPRETER WYBIERANY PRZEZ URUCHOMIENIE, nie przez `command -v`. Na Windows
# `python3` jest aliasem sklepowym: rozwiazuje sie, uruchamia i drukuje "nie
# znaleziono Python". Pierwsza wersja tej petli brala go i piec asercji nizej
# porownywalo sie z komunikatem bledu -- trzy z nich PRZESZLY, bo tekst bledu
# nie przekracza 80 kolumn. To ta sama pomylka co R1: nazwa sie rozwiazuje nie
# znaczy, ze dziala.
PY=""
for c in python3 python; do "$c" -c 'import sys' >/dev/null 2>&1 && { PY="$c"; break; }; done
[ -n "$PY" ] || { echo "FATAL: brak dzialajacego interpretera python" >&2; exit 2; }

screen() {   # <dodatkowe argumenty> -> ekran jako tekst
    "$PY" "$TUI" --render-once --jobs "$FIX/jobs.json" --monitors "$FIX/monitors.json" "$@" 2>&1
}
S="$(screen)"

# --- CO MUSI BYC WIDOCZNE ZAWSZE -------------------------------------------
# Zmierzone na produkcji 2026-09-08: crontab roota nie mial ani jednego bloku
# zarzadzanego, a konto delegowane mialo blok z JEDENASTOMA liniami. Operator
# patrzacy na "swoj" swiat zobaczylby pustke na hoscie robiacym jedenascie
# zadan -- dlatego konto jest w naglowku, nie w ustawieniach.
if printf '%s' "$S" | grep -q 'konto backupacct'; then
    ok "tui: naglowek nazywa KONTO, ktorego crontab jest czytany"
else
    bad "tui: naglowek nazywa konto" "$S"
fi
if printf '%s' "$S" | grep -qE 'config: .*jobs\..*\.conf'; then
    ok "tui: ...i config, z ktorego te zadania pochodza"
else
    bad "tui: naglowek nazywa config" "$S"
fi
# PODSUMOWANIE LICZBAMI, nie etykieta kontraktu. Wlasciciel, 2026-09-08:
# "Nie rozumiem co to znaczy najgorszy werdykt. Nieczytelne." Ekran ma
# odpowiadac na pytanie "czy moje kopie sa aktualne", nie uczyc slownika.
if printf '%s' "$S" | grep -q '4 zadania: 1 stare, 1 spóźnione, 1 bez monitora, 1 aktualne'; then
    ok "tui: ...i stan calego hosta LICZBAMI, u gory, bez slownika werdyktow"
else
    bad "tui: naglowek podsumowuje host liczbami" "$S"
fi

# --- KIERUNEK RYSOWANY WOKOL "TEN HOST" ------------------------------------
# Strona strzalki, nie kolejnosc nazw: inaczej "jestem kolektorem" i "jestem
# zrodlem" trzeba odczytac z nazw i domyslic sie reszty.
if printf '%s' "$S" | grep -qE '^.-> tutaj +daily +rpool/ROOT/os'; then
    ok "tui: kopia na ten sam host to '-> tutaj'"
else
    bad "tui: kopia lokalna" "$S"
fi
if printf '%s' "$S" | grep -q -- '-> pve9'; then
    ok "tui: wysylka do peera pokazuje strzalke OD nas, z jego nazwa"
else
    bad "tui: wysylka do peera" "$S"
fi
if printf '%s' "$S" | grep -q -- '<- pve1'; then
    ok "tui: pobranie pokazuje strzalke DO nas"
else
    bad "tui: pobranie" "$S"
fi
if printf '%s' "$S" | grep -q 'porządki'; then
    ok "tui: sekcja prune to porzadki, nie transfer bez celu"
else
    bad "tui: prune" "$S"
fi

# --- WERDYKT PRZY WLASCIWYM WIERSZU ----------------------------------------
# Trzy rozne werdykty w jednym zestawie, kazdy przy swoim zakresie: wiersz,
# ktory pokazuje cudzy werdykt, jest gorszy niz brak werdyktu.
if printf '%s' "$S" | grep -qE 'rpool/ROOT/os .*aktualne'; then
    ok "tui: stan 'aktualne' stoi przy zakresie, ktorego dotyczy"
else
    bad "tui: OK przy swoim zakresie" "$S"
fi
if printf '%s' "$S" | grep -qE 'subvol-100-disk-0 .*spóźnione'; then
    ok "tui: ...'spoznione' przy swoim"
else
    bad "tui: WARNING przy swoim zakresie" "$S"
fi
# TEN JEDEN JEST DYSKRYMINATOREM CALEGO DOPASOWANIA. Dla POBRANIA monitorowany
# jest lokalny CEL, a zakres zadania to zdalne ZRODLO -- dopasowanie po samej
# sciezce nie ma jak ich polaczyc, i pierwsza wersja pokazywala tu "BEZ
# MONITORA", chociaz monitor istnial i mowil KRYTYCZNY. Laczy je etykieta
# relacji, ktora gen-cron stempluje w linii monitora (-L) wlasnie po to.
if printf '%s' "$S" | grep -qE 'vm-100-disk-0 .*stare'; then
    ok "tui: wiersz POBRANIA dostaje werdykt swojego monitora, dopasowany po ETYKIECIE"
else
    bad "tui: pull dopasowany po etykiecie relacji" "$S"
fi
# NIC NIE PILNUJE != WSZYSTKO DOBRZE. Silnik ma na to wlasne zdanie i ekran nie
# ma prawa zlac tego z OK ani z NIEZNANY ("pytalem, nie wiem").
if printf '%s' "$S" | grep -q 'bez monitora'; then
    ok "tui: zadanie, ktorego nikt nie pilnuje, mowi 'bez monitora' -- nie 'aktualne'"
else
    bad "tui: bez monitora nie udaje aktualnego" "$S"
fi

# --- JEDNA PISOWNIA RODZINY -------------------------------------------------
# Transfer stempluje `prefix` (automated_daily_), prune dopasowuje `pattern`
# (automated_daily). W wierszu CLI to nie przeszkadza; na ekranie sasiaduja i
# czytaja sie jak dwie rozne rodziny.
if [ "$(printf '%s' "$S" | grep -c 'automated_daily_')" -eq 0 ] \
   && [ "$(printf '%s' "$S" | grep -c 'automated_daily')" -ge 2 ]; then
    ok "tui: rodzina ma jedna pisownie w calej kolumnie (bez koncowego podkreslenia)"
else
    bad "tui: jedna pisownia rodziny" "$S"
fi

# --- KURSOR I PRZEWIJANIE ---------------------------------------------------
if [ "$(printf '%s' "$S" | grep -c '^>')" -eq 1 ]; then
    ok "tui: dokladnie jeden wiersz jest wskazany kursorem"
else
    bad "tui: jeden kursor" "$S"
fi
# Ekran nizszy niz lista: wiersze musza sie zmiescic, a nie wyleciec poza ramke.
S_SMALL="$(screen --height 12)"
if [ "$(printf '%s' "$S_SMALL" | wc -l)" -le 12 ]; then
    ok "tui: przy niskim oknie ekran nie przekracza jego wysokosci"
else
    bad "tui: ekran miesci sie w oknie" "$(printf '%s' "$S_SMALL" | wc -l) linii"
fi
if [ "$(printf '%s' "$S" | awk '{ if (length($0) > 80) n++ } END { print n+0 }')" -eq 0 ]; then
    ok "tui: zadna linia nie przekracza 80 kolumn"
else
    bad "tui: 80 kolumn" "$(printf '%s' "$S" | awk 'length($0)>80')"
fi

# --- BLOK, KTOREGO NIE DA SIE WYJASNIC, JEST WIERSZEM -----------------------
# Nie przypisem i nie cisza: te linie CHODZA. To ta sama pusta ramka, przed
# ktora powstal `list-jobs`.
U="$("$PY" "$TUI" --render-once --jobs "$FIX/unreadable.json" --monitors "$FIX/monitors.json" 2>&1)"
if printf '%s' "$U" | grep -q '11 linii'; then
    ok "tui: blok bez czytelnego configu jest WIERSZEM, z liczba linii, ktore wykonuje"
else
    bad "tui: nieczytelny blok jest wierszem" "$U"
fi
# `grep -qv` bylo tu bledem: prawdziwe dla KAZDEGO wejscia z wiecej niz jedna
# linia, wiec asercja przechodzila takze na komunikacie bledu.
if ! printf '%s' "$U" | grep -q 'Zero zadan'; then
    ok "tui: ...wiec host z nieczytelnym blokiem nie wyglada na pusty"
else
    bad "tui: host z nieczytelnym blokiem nie wyglada na pusty" "$U"
fi

# --- HOST, KTORY NAPRAWDE NIC NIE MA ---------------------------------------
E="$("$PY" "$TUI" --render-once --jobs "$FIX/empty.json" --monitors "$FIX/empty-mon.json" 2>&1)"
if printf '%s' "$E" | grep -q "NIE znaczy 'host nic nie robi'"; then
    ok "tui: pusty wynik mowi, co znaczy -- brak bloku, nie brak backupow"
else
    bad "tui: pusty wynik tlumaczy sie" "$E"
fi

# LICZEBNIK PO POLSKU: to jest ekran w jezyku wlasciciela, wiec "4 zadania",
# nie "4 zadan". Tanie, i pierwsza wersja mowila zle.
if printf '%s' "$S" | grep -q '4 zadania'; then
    ok "tui: liczebnik odmieniony poprawnie (4 zadania, nie 4 zadan)"
else
    bad "tui: polski liczebnik" "$S"
fi
# I ZADNEGO SLOWNIKA KONTRAKTU NA EKRANIE.
if ! printf '%s' "$S" | grep -qE 'KRYTYCZNY|NIEZNANY|BEZ MON\.|najgorszy werdykt'; then
    ok "tui: na ekranie nie ma etykiet kontraktu monitora, tylko slowa"
else
    bad "tui: ekran nie mowi slownikiem kodow wyjscia" "$S"
fi

# SLOWNICTWO JEST WLASCICIELA, wiec jest przypiete: "aktualne / spóźnione /
# stare / nie odpowiada", plus "bez monitora" jako piaty stan, ktorego jego
# czteroelementowa lista nie obejmowala. Rozdzial dwoch ostatnich jest celowy:
# "nie odpowiada" = pytalem i nie wiem, "bez monitora" = nikt nie pyta.
for w in aktualne stare "bez monitora"; do
    if printf '%s' "$S" | grep -q "$w"; then
        ok "tui: slownik wlasciciela na ekranie: '$w'"
    else
        bad "tui: brakuje slowa '$w'" "$S"
    fi
done

echo "--------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
