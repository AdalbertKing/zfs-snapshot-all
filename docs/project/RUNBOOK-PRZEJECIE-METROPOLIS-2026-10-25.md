# Runbook: przejęcie migawek Metropolis (pve1 28.9, pve2 28.8) -- 1.0

Stan wyjściowy (odczyt 2026-10-24, tylko do odczytu): oba hosty bez relacji; wszystkie zadania
migawek w crontabie konta `zfsbackup`, blok gen-cron z `/etc/zfs-snapshot-all/jobs.pve1.v4.conf`
i `jobs.pve2.v4.conf`. pve1 robi migawki u siebie, pvesr niesie je co 3 h na pve2, pve2 kopiuje
pasywnie z replik do `hdd/backups/pve2/<ścieżka>`.

Przećwiczone w labie 2026-10-24 (pve11 = „pve1”, pve9 = „pve2”, datasety `hdd/mt`, kopie
`hdd/bkmt`). Wymaga pakietu z gałęzi `feat/local-passive-copy` na main.

## Zasady

- Host po hoście: najpierw pve1, potem pve2. Po każdym kroku sprawdzenie z sekcji „Sprawdź”.
- Kolejność na każdym hoście: NAJPIERW usuń stare sekcje (`edit-config`), POTEM załóż relację.
  Odwrotnie strażnik nakładania odmówi (stare sekcje dzieci pod nowym miejscem).
- Okno bez migawek między krokami: minuty. Nie robić tego w minucie, o której chodzą stare zadania.
- Konto relacji: `zfsbackup` (Zaawansowane -> Konto), jak dziś. Relacje dopisują się do tego
  samego `jobs.pveN.v4.conf`: pakiet bierze config wskazany w linii `# Source:` zainstalowanego
  bloku konta, zanim sięgnie po domyślny (`default_cron_config` w `zfs-backup.sh`); plan pisze
  „Config docelowy: …v4.conf (istnieje -- plan jest ADDYTYWNY)”.
- NIE RUSZAĆ: linie `# ZSA-LAB-PVESR` (subvol-990) -- lab właściciela.
- 101 zostaje bez kopii na pve2 (decyzja właściciela: 4 TB, replika + kopia nie mieszczą się w puli).
- Na pve2 NIE zakładać „Migawek lokalnych” na replikach (`hdd/vm-disks/subvol-107…`,
  `rpool/data/vm-106…`): migawki replik robi pve1. Strażnik pvesr (U69) dopiero w 1.1.

## 0. Przed startem (oba hosty)

    ts=$(date +%Y%m%d-%H%M); mkdir -p /root/przejecie-$ts
    crontab -l > /root/przejecie-$ts/crontab.root
    crontab -u zfsbackup -l > /root/przejecie-$ts/crontab.zfsbackup
    cp -a /etc/zfs-snapshot-all /root/przejecie-$ts/etc
    zfs list -H -t snapshot -o name | grep -c automated_ > /root/przejecie-$ts/liczba-migawek
    cd /root/scripts/zfs-snapshot-all && git log -1 --format=%h     # musi zawierać local-passive-copy

## 1. pve1 -- migawki lokalne

1. `zfs-backup edit-config --account=zfsbackup`: usuń sekcje `[dataset:…]` datasetów relacji A
   (vm-disks 101-0, 101-1, 107, 100 i rpool/data/vm-106). Szablony i `[excluded:…]` zostają.
   Zapis -> różnica crona -> potwierdź. **Nigdy nie usuwaj naraz WSZYSTKICH reguł**: config bez
   żadnej reguły gen-cron odrzuca (próba w labie); dlatego relacje po kolei -- A, potem B
   (usuń vm-102, załóż B), potem C (usuń rpool/ROOT/pve-1, załóż C). Przy ostatniej relacji
   konfig ma już sekcje A i B.
2. GUI F3 -> Ins -> „Migawki lokalne”, konto `zfsbackup`:
   - relacja A: 101-0, 101-1, 107, 100 (hdd/vm-disks) i rpool/data/vm-106; „Ręcznie”: GFS albo
     płaski wg dzisiejszego (dziś: płaski keep h24 d7 w4 m6), zamrażanie na dobowych i rzadszych;
   - relacja B: vm-102: dobowe 7, tygodniowe 4, miesięczne 6, BEZ zamrażania (dziś quiesce = no);
   - relacja C: rpool/ROOT/pve-1: dobowe 7.
   Pytania „kto robi te migawki” tu nie ma (migawki lokalne). Stare `automated_*` wchodzą do
   retencji relacji po prefiksie i wygasają same.

### Sprawdź (pve1)

    crontab -u zfsbackup -l | grep -c 'snapshot (vm-disks)'      # 0 -- stare linie zniknęły
    crontab -u zfsbackup -l | grep -c 'profile__relacja-'        # nowe linie są (nazwy zadań relacji)
    pvesr status                                                 # replikacje bez błędu
    # F3: relacje A/B/C "działa"; F7 na A -> nowa migawka automated_hourly_ na każdym dysku

## 2. pve2 -- kopie lokalne (pasywne z replik)

1. `zfs-backup edit-config --account=zfsbackup`: usuń `[dataset:hdd/vm-disks/subvol-107-disk-0]`,
   `[dataset:rpool/data/vm-106-disk-0]`, `[dataset:hdd/vm-disks/subvol-103-disk-0]`,
   `[dataset:rpool/ROOT/pve-1]` oraz CAŁE `[prune:hdd/backups]` (GFS na całym magazynie) i
   `[prune:hdd/backups/pve2/…]` (monitory kopii). Stary GFS obejmuje cały `hdd/backups`, więc
   zostawiony przycinałby też kopie relacji -- zdejmujemy go w tym samym kroku.
   `[prune-bookmarks:…]` zostają -- z nimi config nie jest pusty, więc tu wolno zdjąć wszystkie
   kopie naraz (zmierzone w labie: na pve9 config z samymi zakładkami zainstalował się).
2. GUI F3 -> Ins -> „Kopia lokalna”, cel „Wpisz ścieżkę…” = `hdd/backups/pve2`, konto `zfsbackup`
   (ścieżka kopii wychodzi ta sama co dziś: `hdd/backups/pve2/hdd/vm-disks/…`, więc bez pełnego seeda):
   - 107 (replika): „Migawki na źródle” -> **łańcuch** (komenda dostaje `--passive`); „Ręcznie”:
     GFS h24 d7 w4, bez zamrażania;
   - 106 (replika): **łańcuch**; „Ręcznie”: dobowe 7, tygodniowe 4 (bez godzinowych -- dziś BIM
     kopiowany raz na dobę);
   - 103 (własny dataset pve2, urbackup): **resztki** (migawki robił stary cron); „Ręcznie”:
     tylko tygodniowe 4; retencja źródła tygodniowe 4;
   - rpool/ROOT/pve-1 (własny root pve2): **resztki**; dobowe 7, retencja źródła dobowe 7.

### Sprawdź (pve2)

    crontab -u zfsbackup -l | grep -E 'snapget.*-e' | wc -l       # linie kopii z replik: z -e
    crontab -u zfsbackup -l | grep delsnaps | grep -E '"(hdd/vm-disks|rpool/data)/' # PUSTE: replik nikt nie przycina
    pvesr status                                                  # replikacje z pve1 bez błędu
    # F3: relacje "działa", kopie "aktualne"; F7 na kopii 107 -> "Snapshot already exists" albo przyrost

## Wycofanie (host po hoście)

    # usuń relacje (F3 -> Del, kopii NIE kasować), potem przywróć config i crona konta:
    cp /root/przejecie-$ts/etc/jobs.pveN.v4.conf /etc/zfs-snapshot-all/
    crontab -u zfsbackup /root/przejecie-$ts/crontab.zfsbackup

## Znane ograniczenia (1.0)

- Retencja GFS po stronie celu renderuje się płasko (`delsnaps -H24` bez `-G`); przy jednej
  migawce na okres skutek ten sam. Do naprawy osobno.
- Strażnik pvesr (U69, automatyczna pauza/odmowa na replikach) -- 1.1.
