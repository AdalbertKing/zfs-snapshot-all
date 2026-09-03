# Wdrożenie: kolektor, dwa źródła, replika na dyskach wymiennych

Instrukcja spisana z **faktycznie wykonanych komend** trzeciego przelotu labu
(2026-08-30) — rozbiórka do zera i odbudowa od nowa, bez zacięcia. Każda
komenda poniżej została uruchomiona na żywych hostach; wyjścia skrócone do
istoty. Wersja kodu: `main` ≥ PR #194.

Dwa poprzednie przeloty tego samego kształtu wyciągnęły jedenaście wad pakietu
i wszystkie są naprawione; ta instrukcja opisuje stan **po** nich. Historia
znalezisk jest w `docs/PROJECT_STATUS.md`.

## Topologia

```
192.168.28.9  (pve1)                       192.168.28.99 (pve9)
hdd/labsrc            ──backup──►          hdd/backups/192.168.28.9/…
  ├ vm-900-disk-0                            (kolektor)
  └ vm-900-disk-1                                 │
                                                  │ replika
192.168.28.8  (pve2)                              ▼
hdd/labsrc            ──backup──►          pula `repl` na dysku USB
  ├ vm-900-disk-0                          (dwa dyski, ta sama nazwa puli,
  └ vm-900-disk-1                           różne GUID-y = rotacja)
```

Role: **kolektor ciągnie** (`pull`) z obu źródeł kontem delegowanym, a replika
jest kopią tego, co kolektor już ma, na nośnik, który się wypina.

## 0. Wymagania wstępne

**Na produkcyjnych hostach źródłowych zakładaj OSOBNE datasety labowe.**
Produkcji nie dotykamy, a nadanie obejmie wyłącznie to, co wskażesz:

```bash
zfs create hdd/labsrc
zfs create hdd/labsrc/vm-900-disk-0
zfs create hdd/labsrc/vm-900-disk-1
```

**Nośnik przygotowuje się raz, ręcznie.** To celowe: dataset bazowy na dysku
jest tym, co mówi bramce, że w gnieździe leży **właściwy** dysk.

```bash
zpool create -f -o ashift=12 repl /dev/disk/by-id/<dysk>
zfs create repl/replica
zpool export repl
```

Dwa dyski rotacyjne dostają **tę samą nazwę puli** i różne GUID-y. Bramka
rozpoznaje nośnik po GUID-zie, nie po nazwie, więc rotacja działa, a dwa dyski
włożone naraz są **odmawiane** z nazwaniem obu.

## 1. Wdrożenie źródła — trzy kroki, nie jeden

Pierwszy krok buduje wsad i **odmawia dalej**. To nie jest błąd:

```bash
# na kolektorze
./zfs-backup.sh --source=192.168.28.9:hdd/labsrc \
                --target=hdd/backups \
                --local-user=zfsbackup \
                --name=src9 \
                --install --yes --manual-join
```

```
>>> created target dataset hdd/backups/192.168.28.9
>>> Wsad gotowy: /root/scripts/pairing/pve9-to-192.168.28.9.tgz
FATAL: cannot reach zfsbackup-pve9@192.168.28.9 to find out whether it has
signed a scope ... Refusing; nothing was changed.
```

Kolektor nie ma prawa **zgadywać**, co źródło mu nadało. Dopóki źródło nie
podpisze zakresu, replikowanie „tego, co zapamiętałem" byłoby cichym
rozjazdem uprawnień z rzeczywistością.

Krok drugi — **na źródle**, z jego własnej konsoli:

```bash
scp <kolektor>:/root/scripts/pairing/pve9-to-192.168.28.9.tgz /root/
./deploy.sh --join=/root/pve9-to-192.168.28.9.tgz
```

Zapyta o **liczbę datasetów**, nie o „t/n". To celowe: liczbę trzeba
przeczytać, a odruchem się jej nie klepnie.

```
>>> Kolektor prosil o: hdd/labsrc
>>> Przyjecie nada kontu zfsbackup-pve9 prawa
>>>   snapshot,destroy,mount,send,hold,release,bookmark
>>> na 3 dataset(ach), w tym 2 wolumen(ach) maszyn, lacznie 40.5 MiB.
Wpisz liczbe datasetow (3) aby ZAAKCEPTOWAC, [e]dytuj, [n]przerwij:
```

Krok trzeci — **to samo polecenie co w kroku pierwszym**. Wznawia i kończy:
zasiew, weryfikacja punktu końcowego, instalacja crona.

```
>>> client 'src9' is active; endpoint and installed cron both use '192.168.28.9:22'.
```

Powtarzalność jest własnością, nie przypadkiem: to polecenie można wywołać
ponownie po każdym przerwaniu i podejmie od miejsca, w którym stanęło.

## 2. Drugie źródło — identycznie

```bash
./zfs-backup.sh --source=192.168.28.8:hdd/labsrc --target=hdd/backups \
                --local-user=zfsbackup --name=src8 --install --yes --manual-join
# … przeniesienie wsadu, deploy.sh --join na 28.8, to samo polecenie ponownie
```

**Nie ma tu żadnego kroku „dodaj drugie źródło".** Każda relacja jest osobna i
dostaje własny zestaw sekcji oraz własne minuty.

## 3. Replika na nośnik wymienny

Jedno polecenie, dowolna liczba źródeł — `--source` jest powtarzalne:

```bash
./zfs-backup.sh add-replica weekly \
    --source=hdd/backups/192.168.28.9 \
    --source=hdd/backups/192.168.28.8 \
    --dst=repl/replica \
    --install --yes
```

`add-replica` jest **upsertem**: to samo polecenie z inną listą źródeł zmienia
istniejące zadanie. Domyślny harmonogram to `30 2 * * *` — raz na dobę, po
tierze dziennym. Replika **nie jest lustrem online**: nośnik jest zagrożony
tylko wtedy, gdy jego pula jest zaimportowana, więc liczba biegów **jest**
ekspozycją.

Uruchomienie poza harmonogramem:

```bash
./zfs-backup.sh run-replicas          # bezpieczne o każdej porze
./zfs-backup.sh list-replicas         # inwentarz + żywy stan nośnika
```

Opcjonalnie, **nie domyślnie**, wyzwalacz po włożeniu dysku:

```bash
./zfs-backup.sh install-media-trigger --install
```

## 4. Co ląduje w configu

Jedna relacja to **trzy sekcje**, każda z własną minutą:

```ini
[dataset:hdd/backups/192.168.28.9/hdd/labsrc]
	use_template  = profile__default__standard_hourly
	send_schedule = 57 * * * *
	src           = zfsbackup-pve9@192.168.28.9:hdd/labsrc
	flags         = -K …/pairing-192.168.28.9_ed25519 -k …_alias_known_hosts …
	recursive     = flat
	pair_label    = src9

[prune:hdd/backups/192.168.28.9]          # retencja KOPII, u kolektora
	prune_schedule = 17 * * * *
	gfs            = yes

[prune:zfsbackup-pve9@192.168.28.9:hdd/labsrc]   # retencja ŹRÓDŁA, po SSH
	prune_schedule = 37 * * * *
	ssh_flags      = -K … -k … -O HostKeyAlias=zfs-client-src9 …
```

Trzecia sekcja jest tą, o której najłatwiej zapomnieć: **backup tworzy
snapshoty także na źródle**, a bez jej ograniczenia pula źródła rośnie bez
końca.

Replika ma własny config, bo biegnie jako **root** (potrzebuje `zpool
import/export`), a backupy jako konto delegowane:

```ini
[replica:weekly]
	source    = hdd/backups/192.168.28.9,hdd/backups/192.168.28.8
	dst       = repl/replica
	schedule  = 30 2 * * *
	prefix    = replica_
	media     = removable
	recursive = yes
```

## 5. Co ląduje w harmonogramie

Sześć zadań, **sześć różnych minut** — trzy sloty na relację:

| minuta | zadanie | dotyka |
|---|---|---|
| `:57` | backup src9 | SSH do 28.9 |
| `:01` | backup src8 | SSH do 28.8 |
| `:17` | przycinanie kopii src9 | tylko dysk lokalny |
| `:21` | przycinanie kopii src8 | tylko dysk lokalny |
| `:37` | przycinanie **źródła** src9 | **SSH do 28.9** |
| `:41` | przycinanie **źródła** src8 | **SSH do 28.8** |
| `:30 2` | replika (root) | import/eksport puli |

Minuta bazowa jest wybierana **raz, przy tworzeniu relacji**, z nazwy, i
zapisywana w sekcji. Kolejne sloty to `+20` i `+40`. Nie zmienia się przy
dodaniu trzeciej relacji, więc istniejące linie zostają nietknięte.

Linia zadania wygląda tak:

```
57 * * * * /root/scripts/zfs-snapshot-all/zfs-job.sh "pve9 … backup (src9-labsrc)" \
           --log=/root/scripts/cron.log --notify=/root/scripts/notify-fail.sh \
           --detail=8 -- /home/zfsbackup/zfs-snapshot-all/snapget.sh -m … 
```

Koperta (`ZFS-JOB BEGIN/END`, przechwycenie stderr, powiadomienie) siedzi w
`zfs-job.sh`, a **polecenie silnika zostaje widoczne** po `--`. Linię można
skopiować i uruchomić z ręki — zachowa się dokładnie tak, jak pod cronem.
Powód jest twardy: cron przyjmuje polecenie do **1000 bajtów**, a koperta
inline zajmowała 336 znaków w **każdym** zadaniu.

## 6. Rotacja nośnika

```bash
# dysk A w gnieździe, bieg nocny albo run-replicas — po biegu pula jest
# wyeksportowana i dysk można wyjąć
./zfs-backup.sh list-replicas     # 'available' = w gnieździe, nie zaimportowany
```

Po włożeniu dysku B (inny GUID, ta sama nazwa puli) pierwszy bieg go
**wciągnie**, bo bramka porówna GUID z zapisem i stwierdzi, że to inny nośnik.
Zapis trzyma jedną linię na źródło:

```
guid=3717319648122292429
snap:hdd/backups/192.168.28.9=replica_2026-08-30_16-44-34
snap:hdd/backups/192.168.28.8=replica_2026-08-30_16-44-38
```

Pominięcie biegu wymaga **wszystkich** warunków naraz: ten GUID, każde źródło
ciche, każde źródło udowodnione na tym dysku. Cokolwiek innego — import.

**Dwa dyski naraz są odmawiane**, z `rc=2` i nazwaniem obu:

```
REFUSING: 2 pools named 'repl' are available to import. Rotated media often
share a name, so this is two disks in at once. Unplug one, or import the one
you mean by its id and re-run -- this will not choose for you.
```

**Nośnik z cudzą linią też jest odmawiany.** Jeśli dysk niesie replikę relacji,
której już nie ma, a kolektor ma nową rodzinę snapshotów bez wspólnego
przodka — bramka nazwie obie rodziny i postawi wybór (inny `--dst` albo
`zfs destroy -r` na celu), zamiast sypać co noc błędem ZFS-a.

## 7. Czasy i statystyki

Dwa poziomy, oba już zapisywane, bez dokładania czegokolwiek:

```bash
# poziom zadania: pełna historia, para znaczników na bieg
grep "ZFS-JOB" /home/zfsbackup/cron.log

# poziom datasetu: tryb, czas, objętość, przepustowość
./zfs-backup.sh progress --json
```

Zmierzone na biegu 600 MB:

```
total_bytes = 630279464   done_bytes = 551425752
wire_bytes  = 617611264   rate_bps   = 116537608   (6 s)
```

`done_bytes` to co silnik wepchnął w rurę, `wire_bytes` to co wyszło łączem —
różnica jest kompresją. `-1` znaczy „niemierzalne tutaj" (przy `push` mbuffer
stoi po stronie zdalnej), **nigdy 0**, żeby brak pomiaru nie czytał się jako
bezczynne łącze.

Obserwator próbkuje **co 2 sekundy**, więc transfer krótszy niż tick zostawia
zera. To nie jest brak pomiaru, tylko brak czegokolwiek do zmierzenia.
Rekordy są sprzątane przez `progress_reap()` przy każdym biegu silnika —
7 dni, z pominięciem tych w stanie `running`.

## 8. Rozbiórka — dokładnie odwrotnie

Na kolektorze:

```bash
./zfs-backup.sh remove-replica weekly --install --yes
./zfs-backup.sh remove-client src9
./zfs-backup.sh remove-client src8
./clean-relationships.sh --purge-orphans --yes
zfs destroy -r hdd/backups          # DANE kasuje człowiek, nie narzędzie
```

Na każdym źródle, z jego własnej konsoli:

```bash
./deploy.sh --leave=pve9
./clean-relationships.sh            # ma zakończyć się „nothing orphaned"
```

`remove-replica` na **ostatnim** zadaniu w configu zdejmuje cały blok
zarządzany i mówi o tym wprost. Żaden z tych czasowników nie kasuje datasetów
ani kopii na nośniku: „unpairing ends the relationship, not the backup".

**Kopie na nosniku zdejmuje osobne polecenie** -- od 2026-09-02, bo wczesniej
nie bylo zadnego i po rozbiorce labu 645 M martwej repliki lezalo na dysku bez
czasownika, ktory potrafilby ja choćby nazwac:

```bash
./zfs-backup.sh purge-replica-copy weekly              # plan, nic nie kasuje
./zfs-backup.sh purge-replica-copy weekly --yes        # wykonanie
```

Trzy rzeczy warte zapamietania:

- **Kolejnosc ma znaczenie.** Po `remove-replica` sekcja `[replica:]` znika i
  nic juz nie zapisuje, gdzie ta kopia lezy -- wtedy trzeba podac
  `--dst=POOL/BASE` recznie. Wygodniej odwrotnie: najpierw
  `purge-replica-copy`, potem `remove-replica`.
- **Sam `POOL/BASE` zostaje.** To po nim brama rozpoznaje wlasciwy dysk
  (`--dataset`); jego skasowanie zostawiloby nosnik, ktorego nic nie umie
  zidentyfikowac.
- **Zly nosnik = odmowa.** Polecenie pyta brame, zanim cokolwiek tknie, i przy
  `wrong_medium` konczy bez kasowania. Nosnik obecny, ale wyeksportowany,
  zostanie zaimportowany na czas operacji i wyeksportowany z powrotem --
  wylacznie jesli to ten przebieg go zaimportowal.

## 9. Pułapki, które ten lab znalazł

| pułapka | co robić |
|---|---|
| kolektor bez kanału root-ssh do produkcji | używać `--manual-join` — i dobrze, że tak; lab nie zakłada stałego zaufania root→produkcja |
| konto delegowane dostaje **uwolniony UID** po poprzednim | `--leave` zabiera teraz katalog bramki; audyt musi kończyć się „nothing orphaned" |
| ta sama nazwa relacji użyta ponownie | stary rekord ląduje jako `*.conf.removed-<ts>`; audyt je **wypisuje**, nie kasuje |
| linia crona blisko 1000 bajtów | koperta jest w `zfs-job.sh`; jeśli `crontab` odmówi, komunikat nazwie każde polecenie ponad limit z jego długością |
| harmonogram po reinstalacji | zawsze porównaj przed instalacją: regeneracja z configu vs żywy `crontab -l` |

## 10. Sprawdzenie końcowe

```bash
./zfs-backup.sh status              # obie relacje: state=active
./zfs-backup.sh list-replicas       # nośnik: here / available / away / wrong_medium
./clean-relationships.sh            # „nothing orphaned" na KAŻDYM z trzech hostów
zfs list -r hdd/backups             # dane u kolektora
```
