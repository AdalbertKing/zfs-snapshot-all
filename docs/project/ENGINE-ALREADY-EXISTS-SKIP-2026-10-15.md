# Silniki: skrót „already exists in target” omija regułę P-0 -- prośba o recenzję wstępną

Stan: **PROPOZYCJA, kod silników NIE zmieniony.** Polecenie właściciela 2026-10-15: „B do recenzenta”.
Pliki zamrożone (`docs/project/ENGINE-FREEZE.md`): `snapsend.sh`, `snapget.sh`. Zmiana wymaga
recenzji wstępnej i znacznika `authorizes-frozen` przed implementacją.

## Błąd

Oba silniki mają na początku decyzji o wysyłce ten sam skrót:

- `snapsend.sh` ~1648-1653, `snapget.sh` ~1601-1606:
  jeśli wysyłana migawka (`latest_snap`) już jest na celu i `validate_snapshot` ją potwierdza,
  silnik loguje „Snapshot already exists in target - skipping” i kończy się `return 0`.

Skrót działa **przed** regułą P-0 (właściciel 2026-10-08, wariant D3, testy P5-P10 w `test/snapsend`):

- lądowanie kopii (`BACKUP_LANDING=1`): nadmiar na celu po wspólnej migawce -> `zfs recv -F`, z logiem;
- cel dokładny / ścieżka źródła (`-t`, sync): zapis po wspólnej migawce -> odmowa (push); same puste
  migawki po niej, bez zapisu -> przyjęcie BEZ `-F`, migawki zostają (P10); pull orze, gdy to nie jest dysk
  działającego gościa.

Skrót nie patrzy, czy na celu jest coś **nowszego** niż ta migawka, ani czy po niej coś zapisano.
Gdy wysyłany punkt już jest na celu, P-0 się nie wykonuje.

## Kiedy to się zdarza

Zwykły bieg crona tworzy najpierw nową migawkę, więc skrót prawie nie działa. Działa, gdy nie ma
nic nowego do wysłania:

1. **Przywracanie do punktu, który cel jeszcze ma** (`snapsend -t -e -m <punkt>`). Zmierzone na labie
   2026-10-15 (pve9b, `hdd/test-kreator`, relacja lokalna): silnik zakończył się sukcesem, źródło
   zostało z migawką nowszą niż punkt, zakładką i zapisem po migawce. Przywracanie zgłosiło
   „recovered”. Naprawione po stronie `zfs-restore.sh` (`fix/restore-local-rewind`: jawne cofnięcie
   + kontrola wyniku), więc przywracanie nie zależy już od tej zmiany.
2. **Relacje na istniejących migawkach (`-e`)**, gdy najnowsza migawka źródła jest już na kopii, a
   kopia ma nadmiar (np. źródło cofnięte bez nowej migawki): nadmiar zostaje do pojawienia się nowej
   migawki (wtedy działa P8).

## Proponowana zmiana (w obu silnikach identycznie)

Zawężona po uwadze przeglądu: **lądowanie kopii bez zmian.** Usunięcie nadmiaru na kopii bez transferu
wymagałoby `zfs rollback -r`, a to niszczy także ZAKŁADKI nowsze niż migawka -- w tym zakładkę, od której
replika ciągnie przyrosty (zmierzone, `ENGINE-FREEZE.md`; `recv -F` zakładek nie rusza, dlatego P-0 go
używa). Na kopii nadmiar znika przy pierwszym biegu z nową migawką (P8), więc skrót kosztuje tam tylko
opóźnienie.

Zmiana dotyczy **celu dokładnego** (`-t` / sync, `BACKUP_LANDING=0`): skrót „already exists” tylko wtedy,
gdy ta migawka jest na celu najnowsza i po niej nic nie zapisano. W przeciwnym razie odpowiedź P-0:

- zapis po migawce -> istniejąca odmowa P-0 (push), cel nietknięty;
- same puste migawki po niej, bez zapisu -> bez zmiany zachowania (jak P10: nic nie jest niszczone);
- pull: istniejąca reguła gościa P-0.

Efekt: silnik, wołany wprost na punkt, który cel ma, nie zgłasza sukcesu nad zmienionym celem.

Uwaga do recenzji: `written@` po wcześniejszym `rollback` nigdy nie jest 0 (stała reszta metadanych,
zmierzone 2026-08-31) -- warunek „zapis po migawce” dla celu kiedyś cofanego musi to uwzględnić albo
porównać `referenced` (tak robi kontrola wyniku w `zfs-restore.sh`). Pytanie projektowe dla recenzenta.

## Testy (do dopisania przy implementacji)

`test/snapsend` (prawdziwy ZFS, root), w sekcji P obok P6-P10, oba silniki:

- P11: `-t`, punkt już na celu, zapis po nim: odmowa (push), cel nietknięty; pull wg reguły gościa.
- P12: `-t`, punkt już na celu, tylko pusta migawka po nim: rc=0, migawka zostaje (jak P10).
- P13: lądowanie kopii, nadmiar, brak nowej migawki: bez zmiany (skip), a po nowej migawce -- P8.
- Kontrola negatywna: na obecnych silnikach P11 daje „Snapshot already exists in target - skipping” i rc=0.
