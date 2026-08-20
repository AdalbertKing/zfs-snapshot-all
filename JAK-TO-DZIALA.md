# Jak to działa

Jedna strona. Bez historii, bez uzasadnień, bez numerów recenzji — te rzeczy są
w `docs/` i nie są potrzebne, żeby zrozumieć, co się dzieje na hoście.

## Co to robi

Robi snapshoty ZFS, kopiuje je na drugi dysk albo drugi host, kasuje stare
i krzyczy, jeśli najnowszy zrobił się za stary.

Wszystko inne to szczegóły tych czterech czynności.

## Cztery skrypty, które wykonują pracę

| skrypt | czynność | w jedną stronę |
|---|---|---|
| `snapsend.sh` | **wyślij** | robi snapshot TU i wypycha go TAM |
| `snapget.sh` | **przyciągnij** | robi snapshot TAM i ściąga go TU |
| `delsnaps.sh` | **skasuj** | usuwa stare snapshoty według reguły |
| `check-snap-age.sh` | **sprawdź** | ile lat ma najnowszy snapshot; alarmuje, gdy za dużo |

To są jedyne cztery skrypty, które dotykają snapshotów. `snapsend` i `snapget`
to ten sam program w dwóch kierunkach — dlatego są tak podobne i dlatego celowo
ich nie scalono (kierunek jest tym, co można pomylić).

Żaden z nich nie wie nic o crontabie, configu ani o innych hostach. Dostają
argumenty i robią jedną rzecz.

## Piąty skrypt: ten, który pisze crontab

`gen-cron.sh` **nie robi backupów**. Czyta plik konfiguracyjny i zamienia go na
linie crontaba, które wołają tamte cztery.

```
config  ──gen-cron.sh──>  blok w crontabie  ──cron──>  snapsend/delsnaps/check-snap-age
```

Bez `--install` tylko wypisuje blok na ekran. Z `--install` podmienia go
w crontabie. Zawsze podmienia **cały blok** między znacznikami
`# BEGIN zfs-backup-managed` i `# END`, nigdy pojedynczą linię.

To jest miejsce, w którym siedzi cała „mądrość": sprawdzenia, że config ma sens,
dobieranie flag, odmowy. Silniki są głupie, generator jest ostrożny.

## Co się dzieje na hoście przez dobę

Prawdziwy pve2, minuta po minucie:

```
BLOK ZARZĄDZANY (pisze go gen-cron.sh, konto zfsbackup)
  :05  co godzinę    snapsend   kopiuje replikę kontenera 107 do hdd/backups
  :51  co godzinę    delsnaps   przycina hdd/backups drabinką GFS
  */15               check-snap-age   trzy monitory świeżości
  0:21 codziennie    snapsend   backup systemu (rpool/ROOT)
  0:31 w niedzielę   snapsend   backup tygodniowy kontenera 103
  0:41 codziennie    delsnaps   przycięcie systemu
  0:43 w niedzielę   delsnaps   przycięcie tygodniowe
  4:00 codziennie    snapsend   backup dysku VM 106
  4:30 codziennie    delsnaps   sprzątanie osieroconych zakładek

POZA BLOKIEM (nie tyka ich gen-cron.sh)
  :15  co godzinę    git pull       host dociąga nową wersję skryptów
  7:00 codziennie    alert-digest   jeden mail z podsumowaniem doby
```

Każda linia zapisuje początek i koniec do `cron.log` i woła `notify-fail.sh`,
jeśli coś zwróciło błąd.

**Wdrożenie to `git pull` o :15.** Nigdy nie kopiuje się skryptów na host ręcznie.

## Config: pięć pojęć

Plik `jobs.<host>.conf`. Sekcje w nawiasach kwadratowych.

```ini
[defaults]                  # nazwa hosta w mailach, domyślny cel kopii
	host_label = pve2
	dst        = hdd/backups/pve2

[template:hourly]           # POLITYKA: kiedy i ile trzymać
	send_schedule  = 37 * * * *      # kiedy robić i wysyłać
	prefix         = automated_hourly_   # jak nazwać
	prune_schedule = 51 * * * *      # kiedy kasować
	pattern        = automated_hourly    # co kasować
	keep           = 24              # ile zostawić
	monitor_warn   = 90m             # kiedy ostrzec
	monitor_crit   = 3h              # kiedy alarmować

[dataset:rpool/data/vm-106-disk-0]   # KTÓRY dataset, KTÓRA polityka
	use_template = hourly,daily,weekly   # jeden dataset, trzy tiery
	notify       = BIM server

[prune:hdd/backups]         # kasowanie na ścieżce, której NIE tworzymy sami
	use_template = store_hourly
	recursive    = yes
```

To jest **skrót** — pominięte są sekcje `[template:daily]`, `[template:weekly]`
i `[template:store_hourly]`, do których odwołują się dwie ostatnie sekcje.
Prawdziwe pliki leżą w `cron-configs/`.

Trzy rzeczy warto zapamiętać:

- **`prefix` to co tworzymy, `pattern` to co kasujemy.** Muszą do siebie pasować
  — `delsnaps` dopasowuje po początku nazwy.
- **`[dataset:]` to nasze, `[prune:]` to cudze.** Pierwsze robi snapshoty
  i kasuje własne; drugie tylko kasuje na magazynie, który zapełnia ktoś inny.
- **Monitor nie ma własnej sekcji.** Powstaje sam, wszędzie gdzie tier ma
  `pattern` i progi.

## Gdzie leży stan

```
/etc/zfs-snapshot-all/jobs.<host>.conf     config (jedyne źródło prawdy)
/etc/zfs-snapshot-all/clients/             relacje z innymi hostami
/var/spool/cron/crontabs/zfsbackup         wygenerowany blok
/home/zfsbackup/cron.log                   co się działo
/root/scripts/zfs-snapshot-all             checkout roota
/home/zfsbackup/zfs-snapshot-all           checkout konta (to on chodzi z crona)
```

Zadania chodzą jako konto `zfsbackup`, nie jako root. Dlatego są dwa checkouty:
`/root` ma prawa 0700 i konto nie może tam zajrzeć.

## Reszta plików — po co są

Nic z tego nie chodzi z crona co godzinę:

- `zfs-backup.sh` — nakładka do zakładania relacji między dwoma hostami
  (`add-client`, `activate`, `pause`). Woła `gen-cron.sh` pod spodem.
- `deploy.sh` — stawianie hosta od zera: konto, uprawnienia ZFS, alerty, logrotate.
- `lib-*.sh` — kod wspólny. `lib-zfs-snap.sh` to serce obu silników.
- `cron2conf.sh` — odtwarza config z crontaba, gdy config zginął.
- `zfs-restore.sh` — odtwarzanie danych ze snapshotu.
- `update-control.sh` — aktualizacja i cofanie aktualizacji, żyje poza checkoutem.
- `zfs-pair-gate.sh`, `zfs-quiesce-helper.sh` — wąskie uprawnienia dla konta
  na drugim hoście.

## Jeśli coś nie działa — kolejność patrzenia

1. `grep ZFS-JOB /home/zfsbackup/cron.log | tail` — czy zadanie w ogóle wystartowało
   (`BEGIN` bez `END` = umarło w trakcie).
2. `gen-cron.sh -c <config>` bez `--install` — czy config się w ogóle generuje.
3. Porównaj wynik z żywym crontabem, zanim cokolwiek zainstalujesz.
4. `zfs list -t snapshot <dataset>` — czy snapshoty naprawdę są.

**Przed każdą instalacją crontaba: kopia zapasowa i diff.** To jedyna operacja
w tym pakiecie, która potrafi po cichu skasować cudzą pracę.
