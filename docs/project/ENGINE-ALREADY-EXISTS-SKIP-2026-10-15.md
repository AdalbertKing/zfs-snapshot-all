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
- cel dokładny / ścieżka źródła (`-t`, sync): zapis po wspólnej migawce -> odmowa (push); pull orze,
  gdy to nie jest dysk działającego gościa.

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

Skrót „already exists” tylko wtedy, gdy na celu ta migawka jest **najnowsza** (brak migawek po niej
na celu) **i** `written@<ta migawka>` na celu jest 0 (dla lądowania kopii; na celu dokładnym
`written@` także). W każdym innym przypadku przejście do istniejącej ścieżki P-0 z `common_snapshot`
= ta migawka:

- lądowanie: odrzucenie nadmiaru (`zfs recv -F` bez strumienia nie istnieje, więc potrzebna jest
  operacja bez transferu: `zfs rollback -r <cel>@<migawka>` z tym samym logiem
  „follows its source -- discarding …”), albo
- cel dokładny: odmowa z istniejącym komunikatem P-0 (push), pull: jak P-0.

Uwaga do recenzji: `written@` po wcześniejszym `rollback` nigdy nie jest 0 (stała reszta metadanych,
zmierzone 2026-08-31) -- dla celu, który był kiedyś cofany, warunek „zapis po migawce” musi to
uwzględnić albo zostać zastąpiony porównaniem `referenced`. To jest pytanie projektowe dla recenzenta.

## Testy (do dopisania przy implementacji)

`test/snapsend` (prawdziwy ZFS, root), w sekcji P obok P6-P10, oba silniki:

- P11: kopia ma nadmiar (ręczna migawka po najnowszej migawce źródła), źródło BEZ nowej migawki,
  `-e`: kopia podąża za źródłem (nadmiar zdjęty, komunikat P-0), rc=0.
- P12: to samo z zapisem na kopii.
- P13: `-t`, punkt już na celu, zapis po nim: odmowa (push), cel nietknięty.
- Kontrola negatywna: na obecnych silnikach P11-P13 dają „already exists -- skipping” i rc=0.
