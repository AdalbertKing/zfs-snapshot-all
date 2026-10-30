# Jak to działa

Wersja angielska: [HOW-IT-WORKS.md](../en/HOW-IT-WORKS.md).

Jedna strona. Bez historii, bez uzasadnień, bez numerów recenzji — te rzeczy są
w `docs/` i nie są potrzebne, żeby zrozumieć, co się dzieje na hoście.

## Co to robi

Robi snapshoty ZFS, kopiuje je na drugi dysk albo drugi host, kasuje stare
i krzyczy, jeśli najnowszy zrobił się za stary.

Wszystko inne to szczegóły tych czterech czynności.

## Silniki: cztery skrypty, które dotykają snapshotów

| skrypt | czynność | w jedną stronę |
|---|---|---|
| `snapsend.sh` | **wyślij** | robi snapshot TU i wypycha go TAM |
| `snapget.sh` | **przyciągnij** | robi snapshot TAM i ściąga go TU |
| `delsnaps.sh` | **skasuj** | usuwa stare snapshoty według reguły |
| `check-snap-age.sh` | **sprawdź** | jak stary jest najnowszy snapshot (progi ostrzeżenia i alarmu, np. 90m / 3h) |

`snapsend` i `snapget` to ten sam program w dwóch kierunkach — dlatego są tak
podobne i dlatego celowo ich nie scalono (kierunek jest tym, co można pomylić).

Żaden z silników nie wie nic o crontabie, configu ani o innych hostach. Dostają
argumenty i robią jedną rzecz.

## Reszta pakietu: kto te silniki woła i stawia

| skrypt | rola |
|---|---|
| `zfs-backup.sh` | **główne wejście dla admina**: zakładanie i zmiana relacji między hostami (`add-client`, `activate-client`, `pause-client`, `status` …) oraz `zfs-backup.sh gui` |
| `gen-cron.sh` | zamienia config na blok crontaba; sam **nie robi backupów** |
| `deploy.sh` | stawianie hosta od zera: konto, uprawnienia ZFS, alerty, logrotate |
| `zfs-restore.sh` | odtwarzanie danych ze snapshotu |
| `zfs-job.sh` | opakowanie każdej linii crona: zapisuje początek i koniec do `cron.log`, woła `notify-fail.sh` przy błędzie |
| `lib-*.sh` | kod wspólny; `lib-zfs-snap.sh` to serce obu silników transferu |
| `update-control.sh` | aktualizacja i cofanie aktualizacji |
| `zfs-pair-gate.sh`, `zfs-quiesce-helper.sh` | wąskie uprawnienia dla konta na drugim hoście |

## GUI

`zfs-backup gui` otwiera ekran w terminalu (whiptail), obsługiwany klawiszami
funkcyjnymi: F2 Przebiegi, F3 Relacje (Ins nowa, Enter okno, `e` zmień), F4 Kopie
(F7 albo Enter na migawce przegląda pliki, F9 przywraca, także z dysku), F6 Replika, F10 Ustawienia. To te same operacje co w CLI `zfs-backup.sh`, tylko w oknach —
GUI woła te same czasowniki, więc config i crontab wychodzą identyczne.

## Skrypt, który pisze crontab

`gen-cron.sh` czyta plik konfiguracyjny i zamienia go na linie crontaba, które
wołają silniki.

```
config  ──gen-cron.sh──>  blok w crontabie  ──cron──>  zfs-job.sh ──> snapsend/delsnaps/check-snap-age
```

Bez `--install` tylko wypisuje blok na ekran. Z `--install` podmienia go
w crontabie. Zawsze podmienia **cały blok** między znacznikami
`# BEGIN zfs-backup-managed` i `# END zfs-backup-managed`, nigdy pojedynczą linię.

To jest miejsce, w którym siedzi cała „mądrość": sprawdzenia, że config ma sens,
dobieranie flag, odmowy. Silniki są głupie, generator jest ostrożny.

## Co się dzieje na hoście przez dobę

Przykład (godziny zależą od configu):

```
BLOK ZARZĄDZANY (pisze go gen-cron.sh)
  co godzinę         snapsend / snapget   migawka i kopia
  co godzinę         delsnaps             przycięcie kopii drabinką GFS
  */15               check-snap-age       monitory świeżości
  raz na dobę        snapsend / snapget   tier dobowy
  raz na tydzień     snapsend / snapget   tier tygodniowy
  po wysyłce         delsnaps             przycięcie danego tieru

POZA BLOKIEM (nie tyka ich gen-cron.sh)
  :15  co godzinę    git pull       host dociąga nową wersję skryptów
  7:00 codziennie    alert-digest   jeden mail z podsumowaniem doby
```

Każda linia zapisuje początek i koniec do `cron.log` (`ZFS-JOB BEGIN` / `END`)
i woła `notify-fail.sh`, jeśli coś zwróciło błąd.

**Wdrożenie to `git pull` o :15.** Pakiet trafia na host przez `git clone`; gdy host
nie sięga repozytorium, `prepare-source` wysyła przez `scp` paczkę (bundle)
z bieżącego checkoutu i rozpakowuje ją na hoście.

## Config: relacja jako jeden blok

Plik `jobs.<host>.conf`, sekcje w nawiasach kwadratowych. Relację założoną z GUI
albo z `zfs-backup.sh` narzędzie zapisuje samo:

- blok `[relation:NAZWA]` niesie politykę: tiery, minuty, retencję i progi monitora;
- `[dataset:…]` wskazuje dataset i relację (`relation`, `side`); `[prune:…]` kasuje na drugiej stronie;
- `prefix` to co tworzymy, `pattern` to co kasujemy — muszą do siebie pasować;
- monitor nie ma własnej sekcji, powstaje tam, gdzie tier ma `pattern` i progi;
- pełny przykład z objaśnieniem: [WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md), sekcja 6.

## Gdzie leży stan

```
/etc/zfs-snapshot-all/jobs.<host>.conf     config (jedyne źródło prawdy)
/etc/zfs-snapshot-all/clients/             relacje z innymi hostami
crontab konta (blok zfs-backup-managed)    wygenerowany blok
cron.log                                   co się działo (obok skryptów)
```

## Konto, na którym chodzą zadania

Gdy przy zakładaniu relacji nie podasz `--local-user`, zadania chodzą jako
**root**. Gdy podasz (np. `--local-user=zfsbackup`), chodzą jako to
delegowane konto z wąskimi uprawnieniami ZFS, a jego crontab dostaje blok.
Konto delegowane musi móc czytać config i skrypty — dlatego config leży
w `/etc/zfs-snapshot-all`, a nie pod `/root`.

## Jeśli coś nie działa — kolejność patrzenia

1. `grep ZFS-JOB cron.log | tail` — czy zadanie w ogóle wystartowało
   (`BEGIN` bez `END` = umarło w trakcie).
2. `gen-cron.sh -c <config>` bez `--install` — czy config się w ogóle generuje.
3. Porównaj wynik z żywym crontabem, zanim cokolwiek zainstalujesz.
4. `zfs list -t snapshot <dataset>` — czy snapshoty naprawdę są.

**Przed każdą instalacją crontaba: kopia zapasowa i diff.** Ryzyko tkwi w ręcznej
edycji configu albo crontaba poza narzędziem. Instalacja przez `zfs-backup.sh`
odmawia, gdy config wygenerowałby blok kasujący działające zadania.
