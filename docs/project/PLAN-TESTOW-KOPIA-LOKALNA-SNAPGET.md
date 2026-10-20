# Plan testów -- kopia lokalna na snapget (2026-10-20)

Właściciel: „Przenieś kopię lokalną na snapget przed 1.0 (jak replikę). Odzysk ciągnięty po 1.0.”
„A potem uruchom testy, które to sprawdzą w każdym wariancie. Rozpisz je wpierw.”

## Co się zmienia

| miejsce | dziś | po zmianie |
|---|---|---|
| `gen-cron.sh` `emit_send`, `dst` lokalny (bez `:`) | `snapsend.sh -m P [flags] SRC DST` | `snapget.sh -m P [flags] SRC DST` (forma lokalna, jak replika) |
| `gen-cron.sh`, `dst` zdalny (push z CLI) | snapsend | bez zmian |
| `gen-cron.sh`, bez `dst` (same migawki lokalne) | snapsend | bez zmian -- snapget bez celu = lustro, nie migawki |
| `zfs-backup.sh local-backup`, seed z kopią | `snapsend.sh` | `snapget.sh` |
| seed: wyłuskanie prefiksu z linii crona | tylko `snapsend.sh` | oba silniki |
| status relacji lokalnej (ostatni wynik ze statystyk) | tylko `"script":"snapsend.sh"` | oba (stare wpisy zostają w logu) |
| odzysk, push zdalny | snapsend | bez zmian (odzysk ciągnięty -- po 1.0) |

Produkcja (pve0, pve2: `dst` lokalny): linie zmienią się dopiero przy ponownym `gen-cron.sh --install`;
samoaktualizacja go nie uruchamia. Przełączenie produkcji -- osobno, z planem i zgodą.

## Testy -- suity (CI i pve9, bez roota tam, gdzie suita tego chce)

| # | wariant | co musi wyjść | gdzie |
|---|---|---|---|
| S1 | linia kopii lokalnej, jedno źródło | `snapget.sh -m P ... "SRC" "DST"` | fixtures gen-cron (`relation-local`, `sendonly-store`, ...) |
| S2 | kilka źródeł w jednej grupie (`a,b`) | jedna linia snapget z listą; snapget ją przyjmuje | fixtures + suita snapget |
| S3 | migawki lokalne bez `dst` | nadal snapsend, bez celu | `configexamples`, fixtures |
| S4 | push zdalny `dst=host:...` | nadal snapsend | fixtures |
| S5 | `-R` (płasko) i `-r` (atomowo) | flaga przeniesiona | localbackup |
| S6 | `-e` (bierne), `-X` (wykluczenia), `-L` (pauza), `-w` (raw), `-q` (zamrożenie gościa) | flagi przeniesione, snapget je przyjmuje | localbackup, fixtures `quiesce*` |
| S7 | seed `local-backup --install` | seed woła snapget, prefiks z linii snapget | localbackup (atrapa silnika) |
| S8 | status relacji lokalnej | ostatni wynik ze statystyk snapget i ze starych snapsend | zfsbackup |
| S9 | nośnik wymienny (media gate) na linii lokalnej | bramka obejmuje linię snapget | mediagate |
| S10 | czytelnicy: TUI (etykieta, nie-lustro), alert-digest, klasyfikator | linia lokalna snapget nie jest brana za pull/lustro/replikę | tui, alertmail, zfsbackup |
| S11 | kontrola negatywna | S1/S7/S8 czerwone na `main` | pve9 |

## Testy na żywo (lab, prawdziwy ZFS)

| # | wariant | dowód |
|---|---|---|
| L1 | nowa kopia lokalna z GUI (kreator „Kopia lokalna”) na pve10 | crontab ma snapget; pierwszy bieg rc=0, kopia jest |
| L2 | **ciągłość**: istniejąca kopia lokalna zrobiona snapsendem, po przełączeniu | następny bieg PRZYROSTOWY (nie od zera), ta sama baza GUID |
| L3 | rekurencja płaska i atomowa | dzieci skopiowane, wykluczenie pominięte |
| L4 | bierne `-e` (cudza rodzina) | bierze najnowszą istniejącą, nie robi własnej |
| L5 | pauza F8 na relacji lokalnej | bieg `skipped_paused`, nic nie skopiowane |
| L6 | rozjazd celu: na celu migawka nowsza od bazy, której źródło nie ma | snapget odmawia (push nadpisywał) -- nowe zachowanie, opisane |
| L7 | F7 „Uruchom teraz” i okno migawek (U38) na relacji lokalnej | działa, para pokazuje `=` |
| L8 | retencja celu (prune) po biegu snapget | prune bez zmian, liczby się zgadzają |
| L9 | odzysk z kopii lokalnej (F11) | bez zmian (nie używa silnika) |
| L10 | powrót: `--rollback` / poprzednia linia | crontab identyczny, bieg rc=0 |
