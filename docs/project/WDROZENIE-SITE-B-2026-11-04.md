# Wdrożenie Site-B 2026-11-04 -- przebieg, poprawki, wnioski

Stan na: 2026-11-04 ok. 12:30 CET. Kolektor pve0 (192.168.11.10), źródło pve1 (192.168.11.11).
Wersja na hostach: 1.0.9 (zfsbackup `f30fbc3`). Uwagi właściciela: `FINISZ-BACKLOG.md` U145-U160.

## 1. Stan po wdrożeniu (zmierzony)

| relacja (pve0, konto `zfsbackup`) | rodzaj | ustawienia | stan |
|---|---|---|---|
| `pve1` | migawki zdalne `rpool/data` na pve1 | `full` + fastprune 168 h (`relacja-pve1-fastprune`), zwykła rodzina `automated_*`, zamrażanie dobowe..roczne (`auto,degrade`), godzinowe bez | biegi rc=0; monitory godzinowy i dobowy z `-S` |
| `lokalna-rpool-data-do-hdd-backups-pve1` | kopia lokalna, pasywna, z replik pvesr | `full`, cel `hdd/backups/pve1` (stare archiwum) | próba: przyrost od `automated_hourly_2026-11-01_20-01-01`; pierwszy bieg 12:52 |
| `migawki-hdd-lxc` | migawki lokalne `hdd/lxc` | `full` | biegi rc=0; obejmuje też CT 105 (U148, do decyzji) |

Zadania replikacji pvesr `100-0` i `106-0` (VM 100, VM 106) pve1 -> pve0 co 2 h, bez błędów. Stare archiwum przycięte do retencji `full`
(52 migawki na dysk, wybór właściciela).

## 2. Co poszło nie tak i co z tym zrobiono

| # | zdarzenie | przyczyna (zweryfikowana) | stan |
|---|---|---|---|
| 1 | instalacja kopii pasywnej do archiwum odmówiła | próba (`snapget.sh -n`) kończy się rc=1, gdy w celu są migawki, których źródło już nie ma; instalator brał to za porażkę | poprawione, wydane 1.0.9 (#1050) -- reguła historii jak w aktywacji relacji (REV-146) |
| 2 | ponowienie tej samej komendy z `--own-snapshots` odrzucone | wznowienie odrzucało każdą odpowiedź, gdy rekord już ją miał -- także tę samą | poprawione na `main` (#1051), niewydane |
| 3 | archiwum założone z celem `hdd/backups` -> pełna kopia 558G | kreator nie wskazuje celu, w którym już jest kopia tych datasetów | do zrobienia: U147, U155, U156 |
| 4 | usunięcie relacji w trakcie pierwszej kopii nie przerwało biegu | delete-relation zdejmuje cron, nie widzi trwającego biegu | przerwane i sprzątnięte ręcznie (za zgodą); do zrobienia: U154 |
| 5 | fałszywe „stare” na relacji sprzed 1.0.6 (roczny szczebel) | monitor bez startu relacji (`-S`) liczy od utworzenia datasetu | relacja założona od nowa; do zrobienia: U158 (mail mówi, że to relacja sprzed 1.0.6) |
| 6 | nazwa `pve1` nie rozwiązuje się na pve0 | brak w `/etc/hosts`, DNS publiczne | nie wada pakietu; U146 |
| 7 | UNKNOWN monitora `hdd/lxc` (11:30, 12:15) | `zfs list -r hdd/lxc` rc=0 bez korzenia; ręcznie 15/15 OK; oba razy w czasie operacji administracyjnych ZFS na tej puli -- przyczyna NIEZNANA | obserwacja: U149 |

## 3. Uwagi właściciela do GUI i maili (skrót)

- Okno „Migawki naszej rodziny już są na źródle” zagmatwane, bez słowa o pvesr -- poprawione na gałęzi
  `gui/chain-text` (U153).
- „Zaawansowane”: „Wstecz” znaczy „gotowe”, „Fastprune” to nazwa robocza (U145).
- „Dokąd”: nawigacja po drzewie zamiast pisania ścieżki; drzewo „toporne” -- wygląd F2 (U155, U156).
- Maile: dzienny raport po relacjach z „DO ZROBIENIA”, pełna statystyka jako załącznik HTML, bez
  usuniętych relacji, wszystkie pule w nagłówku (U157, U160); alert prostym językiem (U158).
- Zamrażanie vm-sql: decyzja właściciela -- dobowe..roczne zamrażane (U150); do sprawdzenia po pierwszym
  biegu dobowym (log `_crash_`, stan qemu-ga w VM 100).

## 4. Do zrobienia po stronie wdrożenia (Site-B)

- po pierwszym biegu kopii (12:52): czy archiwum ma `automated_hourly_2026-11-04_*`;
- rano 05.11: pierwsze dobowe zamrożenie VM 100; czy UNKNOWN na `hdd/lxc` się powtarza;
- po dobie: usunąć `pve0_automated_*` na pve1 i replice pve0 oraz `rpool/data@automated_lancuch_znacznik`
  (zgoda w planie z 04.11);
- decyzja właściciela: CT 105 w `migawki-hdd-lxc` (U148).

## 5. Wnioski na następne wdrożenia

1. Kreator musi sam proponować istniejący cel z tymi datasetami (przyrost) -- pisanie ścieżki z palca
   kosztowało pełną kopię i sprzątanie.
2. Każda operacja niszcząca relację (usunięcie, zmiana celu) musi widzieć trwający bieg.
3. Relacje sprzed 1.0.6 bez startu relacji dają fałszywe alarmy -- przy wdrożeniu na hostach z
   relacjami z 1.0.5 sprawdzić monitory (`check-snap-age` bez `-S`) i założyć je od nowa albo odświeżyć.
4. Źródło z bazą SQL na Windows (VSS): przy każdym wdrożeniu zapytać o zamrażanie przed kreatorem
   (wszystkie gotowe szablony w kreatorze mają [zamraża]; `full`: dobowe..roczne `auto,degrade`).
5. Nazwy hostów: przed wdrożeniem sprawdzić, czy kolektor rozwiązuje nazwę źródła; jeśli nie -- adres.
