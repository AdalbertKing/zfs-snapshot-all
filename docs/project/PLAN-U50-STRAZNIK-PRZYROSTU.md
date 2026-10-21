# U50 -- strażnik podejrzanego przyrostu (ransomware), tylko alarm (plan 2026-10-21)

Właściciel 2026-10-21: „Zgoda. Wpierw check. Domykamy recenzenta i potem zrób alarm” (wariant: 1.0, tylko
alarm, bez blokady kopii). Ustalenia 2026-10-15: „ransomware szyfruje, my widzimy po kaskadowym przyroście”;
„ostrożnie” -- comiesięczna konwersja baz (60 GB, ~3 h) to legalny przyrost i nie może podnosić alarmu.

## Sygnał (zmierzone na pve10 2026-10-21)

Dla przyrostu między dwiema kolejnymi migawkami datasetu dwa oszacowania z metadanych, bez wysyłania danych:

- `L` = `zfs send -nP -i @a ds@b` -- rozmiar logiczny przyrostu;
- `C` = `zfs send -nPc -i @a ds@b` -- ten sam przyrost w blokach takich, jak leżą na dysku (skompresowanych).

`L / C` to kompresowalność samego przyrostu. Lab: tekst i liczby 1,22 (dane testowe, bazy kompresują się
mocniej); dane losowe (jak szyfrogram) dokładnie 1,00.

**Alarm, gdy dla najnowszego przyrostu jednocześnie:**
1. tempo przyrostu `L / czas między migawkami` >= `factor` x mediana tempa z poprzednich przyrostów z ostatnich
   `days` dni (domyślnie 5x, 7 dni, co najmniej 3 przyrosty historii -- inaczej brak normy, brak alarmu);
2. `L` >= `min_mib` (domyślnie 1024 MiB) -- małe datasety nie alarmują od szumu;
3. `L / C` <= `max_ratio_pct` / 100 (domyślnie 1,10) -- przyrost prawie się nie kompresuje.

Konwersja baz: duży przyrost, ale kompresowalny -- warunek 3 go przepuszcza. Szyfrowanie plików: duży i
niekompresowalny -- alarm.

## Zakres

- Datasety „nasze” jak w bezpieczniku (U35): lokalne linie `delsnaps.sh` w zarządzanych blokach crontabów
  (z `-R` dzieci). Działa na źródle i na kolektorze (odebrane migawki mają te same bloki).
- Pomijane z nazwą w `--plan`: `compression=off` (każdy przyrost wygląda na niekompresowalny), za mało historii.
- Dataset z szyfrowaniem w gościu (np. BitLocker na dysku VM) ma zawsze ~1,00 -- alarm zostaje tylko na skok
  przyrostu; opisane jako ograniczenie.
- Tylko alarm: nic nie kasuje, nic nie wstrzymuje. Jeden alarm na migawkę (stan w
  `/var/lib/zfs-snapshot-all/growth-guard`), wyniki oszacowań zapamiętywane po GUID-ach pary (koszt raz).

## Ustawienia (F10, `[growth]`; kolejność jak U35: env > settings.ini > zfs-alert.conf > domyślne)

`growth.alert` off|on (domyślnie **off** -- włącza admin, jak bezpiecznik), `growth.factor` 5 (2-100),
`growth.min_mib` 1024 (1-10485760), `growth.max_ratio_pct` 110 (100-200), `growth.days` 7 (2-60). Zła wartość =
nic, kod 1, alert z nazwą (jak REV-155). Skrypt `hostscripts/growth-guard.sh`, cron co godzinę w bloku hosta,
instalowany przez deploy.

## Testy -- suita (test/alertmail, zaślepki zfs/zpool, prawdziwy skrypt)

| # | przypadek | wynik |
|---|---|---|
| T1 | `alert = off` | nic, bez wywołań `zfs send` |
| T2 | normalny przyrost (tempo jak norma) | brak alarmu |
| T3 | skok x10, kompresja 1,00, ponad `min_mib` | ALARM z datasetem, rozmiarem, tempem, współczynnikiem |
| T4 | skok x10, ale kompresja 2,5 (konwersja baz) | brak alarmu |
| T5 | skok x10, kompresja 1,00, poniżej `min_mib` | brak alarmu |
| T6 | za mało historii (2 przyrosty) | brak alarmu, w `--plan` „brak normy” |
| T7 | `compression=off` | pominięty, w `--plan` powód |
| T8 | ten sam alarm drugi raz (ta sama migawka) | jeden mail, nie dwa |
| T9 | dataset bez linii retencji / linia poza blokiem | nie badany |
| T10 | błąd `zfs list` / `zfs send -nP` / zła liczba | kod 1, alert „strażnik nie działa”, bez fałszywego „OK” |
| T11 | zła wartość ustawienia (każde z 5) | nic, kod 1, alert z nazwą |
| T12 | kolejność env > settings > conf | jak w U35 |
| T13 | kontrola negatywna | T3, T10, T11 czerwone bez strażnika (skrypt nie istnieje / stara wersja) |

## Na żywo (lab pve10, osobny dataset z lz4)

| # | przypadek | dowód |
|---|---|---|
| L1 | 5 migawek z małym przyrostem tekstowym, potem 300 MB losowych | alarm na ostatniej |
| L2 | to samo, ale 300 MB kompresowalnych (tekst) | brak alarmu |
| L3 | instalacja przez deploy: skrypt w /root/scripts, linia crona w bloku hosta | `--check-only` widzi linię |
