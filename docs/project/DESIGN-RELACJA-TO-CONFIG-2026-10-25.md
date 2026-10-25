# Relacja to config -- jeden zakres, jedno drzewo, jeden czasownik (projekt, 2026-10-25)

Decyzja właściciela, 2026-10-25, po przejęciu Metropolis: „Relacja to config i to jest jedyne
źródło prawdy, pochodną są crony. Nie ma tu filozofii.” oraz „To prosty kreator i proste okno.
Nie może mieć tyle wariantów, ile wariantów mają relacje.”

## Skąd ta przebudowa

Każdy rodzaj relacji powstawał osobno i zapisywał „co obejmuje” we własnym miejscu:

- backup / lustro przez sieć: wyjątki jako `-X` w `flags` i w rekordzie (`EXCLUDE_CHILD_n`);
- kopia lokalna: pola `exclude_child_N` w sekcji configu;
- migawki zdalne (snaponly): wyjątki tylko w zgodzie na źródle, czasownik odmawiał `--exclude-*`;
- rekord relacji: `REQUESTED_DATASETS`, `MANAGED_SOURCES`, `RECURSION`;
- źródło: plik zakresu (zgoda) z `include_children` i `exclude`.

Okno zmiany relacji składało `add-source`/`remove-source` i znało rodzaje relacji; kreator
budował inne argumenty dla każdego rodzaju. 25.10 na produkcji (pve2 -> pve1) wyszły z tego
trzy błędy jeden po drugim: wyjątek zamiast usunięcia przy przejściu na rodzica, utrata
rekurencji przy przebudowie po zmianie szablonu, status czytający tylko `[dataset:]`.
Przyczyna wspólna: ta sama informacja w kilku miejscach, różny kod czyta różne z nich.

## Zasada

**Relacja = jej sekcje w configu.** Nic poza configiem nie mówi, co relacja obejmuje. Cron,
zgoda na źródle, status, monitor i GUI wyliczają to z configu.

## Jedna reguła drzewa (każdy rodzaj relacji)

| znak | znaczenie | config |
|---|---|---|
| [x] | dataset i wszystkie dzieci, dziś i przyszłe | jedna sekcja, `recursive = flat` (silnik `-R`) |
| [-] | dataset i tylko dzieci zaznaczone teraz; nowe nie wejdą same | sekcja datasetu `recursive = no`, dalej każde dziecko wg jego kratki |
| [ ] | nie wchodzi, z całym poddrzewem | nic |

Reguła jest rekurencyjna. Wyjątków nie zapisujemy: wynikają z listy sekcji. Nie ma `-X`,
`exclude_child_N` ani `EXCLUDE_CHILD_n` jako nośnika zakresu. Działa z każdym silnikiem
(przycinanie `delsnaps` nie zna `-X`).

Dotyczy: backup, lustro, kopia lokalna, migawki lokalne, migawki zdalne -- bez wyjątków.

## Rekord relacji

Tylko tożsamość i połączenie: host, endpoint, konto, klucze, stan, daty. Listy datasetów nie
są w rekordzie źródłem; jeśli zostają, to jako pamięć podręczna wyliczana z configu.

## Kod

1. `relation_sources NAZWA` -- odczyt: lista (źródło, rekurencja) sekcji źródłowych relacji,
   dla każdego rodzaju. Z niej: status (`sources`), GUI (drzewo), przebudowa, monitor, zgoda.
2. `set-datasets NAZWA ...` -- zapis stanu docelowego z drzewa: sekcje relacji w configu wg
   reguły -> zgoda na źródle wyliczona z configu i zatwierdzona (relacja zdalna) -> cron z
   configu. Rodzaj relacji decyduje tylko o szablonie wypisywanej sekcji, wewnątrz tej funkcji.
3. `add-source` / `remove-source` -- zostają w CLI jako nakładki: lista z configu +/- pozycja
   -> `set-datasets`.
4. Zmiana szablonu (retencja) przepisuje szablony sekcji; listy datasetów nie rusza (bierze ją
   z configu).

## GUI

Kreator i okno zmiany: to samo drzewo, ta sama legenda, to samo wywołanie `set-datasets`
(przy tworzeniu: z nową relacją). Bez warunków po rodzaju relacji.

## Kolejność

1. Inwentaryzacja: każdy odczyt i zapis list datasetów/wyjątków poza configiem; wszystkie
   miejsca, które piszą sekcje relacji, rodzaj po rodzaju.
2. `relation_sources` + testy zgodności z dzisiejszymi configami każdego rodzaju.
3. `set-datasets` + zgoda wyliczana z configu + testy.
4. Przebudowa, status, monitor na `relation_sources`.
5. GUI na `set-datasets`; usunięcie wariantów (`BASKET_NO_EXC`, warunki po `MODE` w drzewie).
6. Stare configi z `-X` / `exclude_child_N`: odczyt jako [-]; pierwsze `set-datasets`
   zamienia je na listę sekcji.
7. Lab: każdy z pięciu rodzajów przez prawdziwe okno (utworzenie, wyjątek, zdjęcie wyjątku,
   zmiana szablonu, ponowne wejście, bieg crona). Potem pve2 (vm-102).

## Co zostaje do tego czasu

Okno zmiany blokuje wyjątki jednakowo we wszystkich relacjach. PR #880 (wyjątki tylko dla
snaponly) zamknięty bez scalenia -- dokładał wariant; poprawka statusu z niego wejdzie w krok 4.
