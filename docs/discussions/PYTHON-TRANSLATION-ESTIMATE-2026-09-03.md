# Wycena tłumaczenia na Python — per plik

Stan: `main` `4c00563`, 2026-09-03. Liczby zmierzone skryptem nad drzewem
(linie, kod = linie bez komentarzy i pustych, funkcje `name() {`, wywołania
zewnętrzne = `zfs|ssh|crontab|install|git|mail|qm|pct|mbuffer|useradd|zpool|logger|flock`
w kodzie, gęstość = wywołania/kod, suity z `deps.conf`, asercje = `ok`/`check`
w suitach pokrywających plik, **suita dzielona przez n plików liczy się 1/n na
plik**; `cron2conf` 29 i `profiles` 39 z tabeli suit w statusie, bo ich
helpery nazywają się inaczej).

## Model (jawny, żeby dało się go zakwestionować)

- dni = kod / tempo + asercje / 40 + 0,5 dnia na CLI i wejście pliku;
- tempo: **200** linii/dzień dla logiki czysto tekstowej (gęstość < 0,02),
  **150** dla mieszanej (< 0,05), **110** dla orkiestracji procesów (≥ 0,05);
- 40 asercji/dzień: każda asercja to specyfikacja do przepisania na test
  Pythona, nie do portowania — 108 wycinków `product_fn`/`product_range` i
  51 asercji grep-ujących źródło mierzą bash jako tekst i nie przenoszą się;
- tempo zakłada jedną osobę, która zna ten kod i `PROJECT_STATUS.md`;
  nie zawiera labów na żywo (każdy przepisany silnik wymaga powtórzenia
  swoich: `LAB-ENGINE-EVAL`, restore dziesięciokrokowy, hostscripts, media).

Warstwy: **1** logika tekstowa (parsery, gramatyki, stan na dysku),
**2** stan i decyzje plus skrypty hostów, **3** silniki, `deploy.sh` i
biblioteka ZFS — zamrożone, dowiedzione na żywo, kandydat do „zostaje w bashu".

## Tabela

| w. | plik | linie | kod | funkcje | wyw. zewn. | gęstość | suity (CI) | asercje (udział) | tempo l/dz | dni |
|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|
| 1 | `cron2conf.sh` | 1152 | 777 | 34 | 13 | 0.017 | 1 (1) | 14 | 200 | 4.7 |
| 1 | `gen-cron.sh` | 4643 | 2150 | 87 | 71 | 0.033 | 11 (10) | 292 | 150 | 22.1 |
| 1 | `lib-backup-common.sh` | 155 | 37 | 6 | 0 | 0.0 | 3 (3) | 212 | 200 | 6.0 |
| 1 | `lib-cron.sh` | 895 | 418 | 27 | 23 | 0.055 | 2 (2) | 187 | 110 | 9.0 |
| 1 | `lib-pairing.sh` | 76 | 22 | 6 | 0 | 0.0 | 7 (7) | 165 | 200 | 4.7 |
| 1 | `lib-profile.sh` | 725 | 292 | 13 | 0 | 0.0 | 1 (0) | 0 | 200 | 2.0 |
| 1 | `lib-record.sh` | 205 | 108 | 4 | 0 | 0.0 | 2 (2) | 93 | 200 | 3.4 |
| 1 | `lib-scope.sh` | 295 | 170 | 9 | 0 | 0.0 | 4 (4) | 160 | 200 | 5.4 |
| 2 | `clean-relationships.sh` | 1212 | 652 | 19 | 24 | 0.037 | 2 (2) | 90 | 150 | 7.1 |
| 2 | `hostscripts/alert-digest.sh` | 1088 | 502 | 9 | 7 | 0.014 | 1 (1) | 14 | 200 | 3.4 |
| 2 | `hostscripts/alert-env.sh` | 45 | 22 | 1 | 0 | 0.0 | 1 (1) | 14 | 200 | 1.0 |
| 2 | `hostscripts/check-pool-capacity.sh` | 155 | 84 | 1 | 16 | 0.19 | 1 (1) | 14 | 110 | 1.6 |
| 2 | `hostscripts/notify-fail.sh` | 90 | 33 | 0 | 1 | 0.03 | 1 (1) | 14 | 150 | 1.1 |
| 2 | `hostscripts/notify-warn.sh` | 39 | 15 | 0 | 1 | 0.067 | 1 (1) | 14 | 110 | 1.0 |
| 2 | `update-control.sh` | 368 | 232 | 10 | 22 | 0.095 | 1 (1) | 18 | 110 | 3.1 |
| 2 | `zfs-backup.sh` | 12193 | 5940 | 203 | 249 | 0.042 | 9 (9) | 234 | 150 | 46.0 |
| 2 | `zfs-job.sh` | 117 | 49 | 1 | 6 | 0.122 | 1 (0) | 0 | 110 | 0.9 |
| 2 | `zfs-media-gate.sh` | 695 | 317 | 13 | 29 | 0.091 | 1 (1) | 142 | 110 | 6.9 |
| 2 | `zfs-pair-gate.sh` | 323 | 120 | 2 | 2 | 0.017 | 1 (1) | 57 | 200 | 2.5 |
| 2 | `zfs-quiesce-helper.sh` | 530 | 250 | 6 | 23 | 0.092 | 1 (1) | 34 | 110 | 3.6 |
| 2 | `zfs-restore.sh` | 4667 | 2080 | 51 | 118 | 0.057 | 3 (3) | 136 | 110 | 22.8 |
| 3 | `check-snap-age.sh` | 363 | 156 | 5 | 7 | 0.045 | 3 (2) | 30 | 150 | 2.3 |
| 3 | `delsnaps.sh` | 1186 | 686 | 19 | 21 | 0.031 | 3 (1) | 77 | 150 | 7.0 |
| 3 | `deploy.sh` | 7115 | 3982 | 89 | 296 | 0.074 | 9 (9) | 208 | 110 | 41.9 |
| 3 | `lib-zfs-snap.sh` | 3147 | 1515 | 94 | 129 | 0.085 | 8 (5) | 520 | 110 | 27.3 |
| 3 | `snapget.sh` | 2618 | 1186 | 16 | 73 | 0.062 | 8 (6) | 133 | 110 | 14.6 |
| 3 | `snapsend.sh` | 2645 | 1131 | 17 | 80 | 0.071 | 9 (6) | 140 | 110 | 14.3 |
| | **razem** | 46742 | 22926 | 742 | 1211 | | | 3012 | | **266** |

Warstwa 1: **57 dni** · warstwa 2: **101 dni** · warstwa 3: **107 dni**.

## Trzy scenariusze

| scenariusz | zakres | dni wg modelu | co zostaje w bashu |
|---|---|---:|---|
| A | warstwa 1 | 57 | wszystko, co woła ZFS/ssh; Python czyta i pisze CONFIG, rekordy, scope, profile, crontab |
| B | warstwy 1+2 | 158 | silniki, `deploy.sh`, `lib-zfs-snap.sh`; Python jest kolektorem i restore, woła silniki jak cron dziś |
| C | wszystko | 266 | nic; do tego laby na żywo od nowa dla każdego silnika |

Uwaga do C: silniki to 1313 wywołań `zfs`, 412 `ssh`; jeden proces Pythona
wołający `zfs send | mbuffer | ssh` nie jest lepszy od basha, a traci dowody
z pve9/pve10. Model liczy C, żeby pokazać koszt, nie żeby go polecać.

## Co obniża, co podnosi

- Obniża: zero `eval`, dane czytane jako dane, jedna gramatyka listy
  (`lib-scope.sh`), round-trip `gen-cron`↔`cron2conf` (gotowy test zgodności
  bash↔Python na tych samych fixture'ach), bliźniaki i kopie pod pomiarem,
  martwy kod usunięty, kontrakty w `deps.conf` z `why`/`check`.
- Podnosi: `zfs-backup.sh` to 203 funkcje i 5,9 tys. linii kodu w jednym
  pliku — przed tłumaczeniem warto go pociąć po czasownikach (dziś ma
  jeden dispatcher); `deploy.sh` niesie 296 wywołań zewnętrznych i 61 `git`
  (self-update), to jest instalator, nie logika; trzy kopie `log`/`warn`/`die`
  i `getopts` z prepassem długich opcji (×10 w trzech plikach) znikają
  w Pythonie, ale ich testy trzeba przepisać na nowy parser.
- Nieznane: `--draft-config` (lab otwarty; jeśli wycofany, warstwa 3 traci
  ~150 linii i jedną suitę), zamknięcie REV-133.

## Kolejność, gdyby decyzja zapadła

1. `lib-record.sh`, `lib-scope.sh`, `lib-pairing.sh`, `lib-profile.sh`,
   `lib-cron.sh` — małe, czyste, z gęstymi suitami; pierwszy tydzień daje
   też odpowiedź, ile naprawdę kosztuje przepisanie 40 asercji dziennie.
2. `gen-cron.sh` + `cron2conf.sh` razem, z round-tripem jako bramką.
3. `zfs-backup.sh` po czasownikach, `zfs-restore.sh` na końcu warstwy 2
   (ścieżka niszcząca, laby do powtórzenia).
4. Warstwa 3 tylko po osobnej decyzji właściciela.
