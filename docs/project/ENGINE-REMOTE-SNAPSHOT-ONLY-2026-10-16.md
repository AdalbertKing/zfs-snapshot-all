# Silnik: migawka na źródle ZDALNYM bez przesyłania -- prośba o recenzję wstępną

Stan: **PROPOZYCJA, kod silników NIE zmieniony.** Zgoda właściciela na zgłoszenie: 2026-10-16.
Plik zamrożony (`docs/project/ENGINE-FREEZE.md`): `snapget.sh`. Zmiana wymaga recenzji wstępnej i znacznika
`authorizes-frozen` przed implementacją.

## Po co

Projekt `docs/project/DESIGN-JEDEN-KOLEKTOR-PVESR-2026-10-16.md`: w klastrze Proxmoxa z replikacją (`pvesr`) jeden
kolektor (B) zarządza całością. Na hoście A robi migawki i je przycina, a dane jadą na B replikacją Proxmoxa. Potrzebna
jest **relacja zdalna, która tworzy migawki na źródle i nic nie przesyła**.

Już jest, bez zmiany silników:

- przycinanie na źródle zdalnym (zadania `src_* prune`: `delsnaps -L … -K …` przez bramkę);
- strażnik wieku na źródle zdalnym.

Brakuje tylko tworzenia migawki zdalnie bez transferu. `snapget.sh` ma tryb „tylko migawka” wyłącznie lokalnie
(`process_dataset`, ~1266):

```bash
if [[ "$src_dataset" == "$tgt_dataset" && -z "$remote_host" ]]; then
    log 1 "Running in local snapshot-only mode"
    snapshot=$(create_snapshot "$src_dataset" "$remote_user" "$remote_host") || return 1
    ...
    return 0
fi
```

`create_snapshot` (~962) obsługuje już host zdalny: `ssh … "zfs snapshot [-r] '<ds>@<name>'"`.

## Proponowana zmiana (tylko `snapget.sh`)

1. **Nowa opcja `-s` = „tylko migawka, bez przesyłania”.** Litera jest wolna w `snapget.sh` i w `snapsend.sh`; `-S`
   jest zajęte (pomijanie rodzica). Jawna opcja zamiast sztuczki `src == tgt`: cel w pobieraniu jest zawsze
   lokalny, więc zdalnego „src == tgt” nie da się wyrazić.
2. Z `-s` drugi argument (cel) **nie jest wymagany**. Pierwszy to `user@host:dataset` albo lokalny dataset.
3. W `process_dataset` gałąź `-s` stoi **wyżej niż dzisiejsza gałąź lokalna** -- po `validate_remote_host` (źródło
   jest zdalne), ale **przed** `check_pool_health "$tgt_dataset"` (~1234) i przed blokiem `-n` (~1246-1264), który
   sonduje cel (`find_common_snapshot`) i drukuje `PLAN=INCREMENTAL/FULL`. Gałąź wola
   `create_snapshot "$src_dataset" "$remote_user" "$remote_host"` i kończy `return 0`, z dwoma warunkami:
   - pauza relacji (`-L`) -- jest na początku programu (~2269-2279), bez zmian;
   - **zamrożenie gościa (`-q`):** w pobieraniu migawkę zamrożoną robi GŁÓWNY przebieg przed pętlą `process_dataset`
     (~2605-2657) i ustawia `QUIESCE_SNAPPED=1` (~2644). Gałąź `-s` przy `QUIESCE_SNAPPED=1` **nie tworzy** drugiej,
     niezamrożonej migawki -- ta sama straż co w `snapsend.sh` (~1276-1279, „already taken inside the quiesce
     window”). Dzisiejsza gałąź lokalna jej nie ma, bo `-q` przy źródle lokalnym jest odrzucane (~2606-2611);
   - rekursja: `-r` = `zfs snapshot -r` (atomowo); `-R` (płasko) = osobna migawka każdego potomka, jak dziś, przez
     rozwinięcie listy w pętli (~2692).
4. Przy `-s` **nie** wykonują się: sonda celu, plan, transfer, zakładki, P-0, holdy. Nic na kolektorze nie powstaje.
5. Dziennik i kod wyjścia jak przy lokalnym trybie „tylko migawka” (dziś `Successfully created local snapshot: …`,
   ~1269): dla źródła zdalnego `Successfully created snapshot on <host>: …`, rc 0; błąd `zfs snapshot` po stronie
   źródła = rc ≠ 0 (z komunikatem zdalnym).
6. `-n` (próba) z `-s`: wypisuje `PLAN=SNAPSHOT-ONLY src=<…>` i nic nie tworzy, spójnie z dzisiejszym `PLAN=`.

## Bliźniak (`snapsend.sh`)

**Bez zmian.** `snapsend.sh` tworzy migawki lokalnie i dziś już ma tryb „tylko migawki” (bez celu). Migawka na
źródle zdalnym ma sens tylko w silniku pobierającym, sterowanym przez kolektor. Litera `-s` zostaje w `snapsend.sh`
wolna, więc parytet opcji nie jest naruszony (nowa opcja istnieje tylko tam, gdzie ma znaczenie).

Według konwencji `ENGINE-FREEZE.md`: wpis odmrożenia z linią `twin: NOT ported -- remote snapshot creation exists only
in the pull engine` (wzór: wpisy ~266, ~335, ~394), a po zmianie `./test/impact.sh --refreeze`. **Suita `twins`**
przypina skrót `process_dataset` (`test/twins/twins.sha256`) i odmówiła już kiedyś jednostronnej edycji
(ENGINE-FREEZE ~569-570), więc jej odnowienie jest świadomą częścią zmiany, nie skutkiem ubocznym.

## Bramka

Do sprawdzenia przed implementacją (lab Metropolis, krok 9 planu): czy bramka pary przepuszcza samo
`zfs snapshot [-r] '<ds>@<name>'` z zakresu relacji. Przy zwykłym pobieraniu przepuszcza je, bo tak dziś powstaje
migawka przed transferem. Spodziewam się tego samego.

## Testy (do napisania razem ze zmianą)

`test/snapget` (atrapa `ssh`/`zfs`):

1. `-s user@host:ds` -> dokładnie jedno wywołanie `zfs snapshot '<ds>@<prefix><stamp>'` po stronie zdalnej; żadnego
   `zfs send`/`recv`/`list` celu; rc 0.
2. `-s -r` -> `zfs snapshot -r`.
3. `-s` z `-R` i listą potomków -> osobna migawka każdego.
4. `-s` przy zapauzowanej relacji (`-L` + znacznik) -> SKIPPED, żadnego `zfs snapshot`.
5. `-s` z `-q` -> zamrożenie przed migawką i odmrożenie po (atrapa gościa), jak przy zwykłym pobieraniu.
6. `-s` i błąd `zfs snapshot` po stronie zdalnej -> rc ≠ 0, komunikat.
7. `-n -s` -> `PLAN=SNAPSHOT-ONLY`, nic nie wywołane.
8. Bez `-s`: dotychczasowe zachowanie bez zmian (cała obecna suita zielona).

Kontrola negatywna: testy 1–7 na `snapget.sh` z `main` -> FAIL (nieznana opcja `-s`).

## Poza silnikiem (po recenzji, bez zamrożenia)

Generator (`gen-cron.sh`): relacja zdalna z celem „nigdzie” -> zadania migawek `snapget -s`, przycinanie źródła, strażnik
wieku; bez przesyłania i bez przycinania na kolektorze. Czasownik/kreator: wybór „kopia: nigdzie”. Zatrzymanie z
alarmem, gdy gość jest na drugim węźle (zmierzone 2026-10-16: nasze migawki na celu odwróconej replikacji są
kasowane przez `recv -F`, a dziennik mówi „sukces”).
