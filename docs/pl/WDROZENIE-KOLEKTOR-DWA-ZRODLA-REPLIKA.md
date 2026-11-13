# Wdrożenie: kolektor, dwa źródła, replika na dyskach wymiennych; łańcuch pasywny

Wersja angielska: [DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](../en/DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md).

Dwa scenariusze na jednym przepływie instalacji:

- **A. Kolektor z dwoma źródłami i repliką na nośniku wymiennym** (sekcje 3–8).
- **B. Łańcuch pasywny: trzy hosty** — źródło → serwer 1 (backup) → serwer 2
  (dublet serwera 1) (sekcja 9).

Wspólne są: wymagania (1), konto zadań (2), przepływ instalacji (3),
rozbiórka (10), pułapki (11) i sprawdzenie końcowe (12).

## 1. Wymagania wstępne

**Pakiety i czas.** Każdy host z kolektorem potrzebuje ZFS, crona i gita. Kontrola
zależności przy instalacji zgłosi brak `crontab`. Wyrównaj strefę czasową z resztą
floty, inaczej nazwy snapshotów niosą inny czas niż `creation` (aktywacja ostrzega
o rozjeździe):

```bash
timedatectl set-timezone Europe/Warsaw
```

**Kanał root-ssh operatora** jest potrzebny tylko wtedy, gdy kolektor ma sam
zrobić stronę źródła (`--join-remotely`, `--grant-remotely`): kolektor musi móc
wykonać `ssh root@źródło` w trybie BatchMode, z pinem źródła w
`/root/.ssh/known_hosts`. Bez tego kanału używaj `--manual-join` (sekcja 3).

**Na produkcyjnych hostach źródłowych zakładaj osobne datasety testowe**, jeśli
wdrażasz po raz pierwszy. Produkcji nie dotykasz, a nadanie obejmie
wyłącznie to, co wskażesz.

## 2. Konto, z którego chodzą zadania

Konto jest decyzją **tej relacji**, podaną przy jej tworzeniu:

- `--local-user=NAZWA` — zadania idą z konta `NAZWA`. Konto jest zakładane, jeśli
  go nie ma, dostaje delegację na źródłach i na celu, a blok zadań trafia do jego
  crontaba;
- brak `--local-user` — zadania idą z **roota**.

Nie ma ustawienia całego hosta ani zgadywania: nazwa konta zostaje zapisana razem
z relacją, więc `activate` i `remove-client` czytają ją z powrotem. Konto po
stronie ŹRÓDŁA (`zfsbackup-<etykieta kolektora>`) zakłada `--join` i żadna z tych
flag go nie dotyczy. Replika biegnie zawsze jako root (potrzebuje `zpool
import/export`).

## 3. Przepływ instalacji źródła

Jedno polecenie na kolektorze, powtarzane identycznie po każdym przerwaniu —
wznawia od miejsca, w którym stanęło. Są dwa warianty strony źródła.

**Wariant ręczny (`--manual-join`) — trzy kroki, nie jeden.** Pierwszy krok buduje
wsad i **odmawia dalej**. To nie jest błąd:

```bash
# na kolektorze
./zfs-backup.sh --source=10.0.0.9:hdd/dane \
                --target=hdd/backups \
                --local-user=zfsbackup \
                --name=src-a \
                --install --yes --manual-join
```

```
>>> created target dataset hdd/backups/10.0.0.9
>>> Package ready: /root/scripts/pairing/kolektor-to-10.0.0.9.tgz
FATAL: cannot reach zfsbackup-kolektor@10.0.0.9 to find out whether it has
signed a scope ... Refusing; nothing was changed.
```

Kolektor nie ma prawa **zgadywać**, co źródło mu nadało. Dopóki źródło nie
podpisze zakresu, replikowanie „tego, co zapamiętałem" byłoby cichym rozjazdem
uprawnień z rzeczywistością.

Krok drugi — **na źródle**, z jego własnej konsoli:

```bash
scp <kolektor>:/root/scripts/pairing/kolektor-to-10.0.0.9.tgz /root/
./deploy.sh --join=/root/kolektor-to-10.0.0.9.tgz
```

Zapyta o **liczbę datasetów**, nie o „t/n". To celowe: liczbę trzeba przeczytać,
a odruchem się jej nie klepnie.

```
>>> Kolektor prosil o: hdd/dane
>>> Przyjecie nada kontu zfsbackup-kolektor prawa
>>>   snapshot,destroy,mount,send,hold,release,bookmark
>>> na 3 dataset(ach), w tym 2 wolumen(ach) maszyn, lacznie 40.5 MiB.
Wpisz liczbe datasetow (3) aby ZAAKCEPTOWAC, [e]dytuj, [n]przerwij:
```

Krok trzeci — **to samo polecenie co w kroku pierwszym**. Kończy pierwszą pełną kopię,
weryfikuje punkt końcowy i instaluje crona:

```
>>> client 'src-a' is active; endpoint and installed cron both use '10.0.0.9:22'.
```

**Wariant zdalny (`--join-remotely`, domyślny).** Gdy masz kanał root-ssh
(sekcja 1), całość to jedno polecenie na kolektorze:

```bash
./zfs-backup.sh --source=10.0.0.9:hdd/dane --target=hdd/backups \
                --local-user=zfsbackup --name=src-a \
                --grant-remotely --yes --install
```

Co robi:

1. zakłada na źródle konto delegowane, klucz i bramkę kanałem root-ssh;
2. z **`--grant-remotely`** zapisuje na źródle zakres RÓWNY ŻĄDANIU i wykonuje tam
   `deploy.sh --commit-scope` (ślad `GRANTED_REMOTELY_BY` w manifeście źródła).
   Bez tej flagi przepływ jest dwudotykowy: polecenie zatrzymuje się z instrukcją,
   co wykonać na źródle, a jego ponowienie wznawia;
3. robi pierwszą pełną kopię (pełny transfer) i weryfikuje granty oraz punkt końcowy;
4. pokazuje podgląd zmian crontaba i instaluje blok zarządzany do crontaba konta
   z sekcji 2. Jeśli w crontabie tego konta jest już blok zarządzany, narzędzie
   bierze config wskazany w jego linii `# Source:`, a sekcje nowej relacji
   dopisuje do tego pliku; sekcje, które już istnieją, zachowują swoje wartości.

## 4. Scenariusz A: topologia

```
10.0.0.9  (zrodlo-a)                       10.0.0.99 (kolektor)
hdd/dane              ──backup──►          hdd/backups/10.0.0.9/…
  ├ vm-900-disk-0                            
  └ vm-900-disk-1                                 │
                                                  │ replika
10.0.0.8  (zrodlo-b)                              ▼
hdd/dane              ──backup──►          pula `repl` na dysku USB
  ├ vm-900-disk-0                          (dwa dyski, ta sama nazwa puli,
  └ vm-900-disk-1                           różne GUID-y = rotacja)
```

**Kolektor ciągnie** (`pull`) z obu źródeł kontem delegowanym, a replika jest
kopią tego, co kolektor już ma, na nośnik, który się wypina.

**Drugie źródło — identycznie** jak pierwsze:

```bash
./zfs-backup.sh --source=10.0.0.8:hdd/dane --target=hdd/backups \
                --local-user=zfsbackup --name=src-b --install --yes --manual-join
# … przeniesienie wsadu, deploy.sh --join na zrodlo-b, to samo polecenie ponownie
```

**Nie ma tu żadnego kroku „dodaj drugie źródło".** Każda relacja jest osobna i
dostaje własny zestaw sekcji oraz własne minuty.

**Nośnik przygotowujesz raz, czasownikiem `prepare-media`.** Dataset bazowy na
dysku mówi bramce, że podłączony jest **właściwy** dysk, i tworzy go to samo
polecenie. Lista wolnych dysków:

```bash
./zfs-backup.sh prepare-media --list
```

Bez `--yes` polecenie tylko pokazuje plan (co zostanie skasowane). Z `--yes`
**kasuje cały dysk**, zakłada pulę (`ashift=12`, `failmode=continue`, kompresja `zstd`, bez
punktu montowania), tworzy dataset bazowy (domyślnie `replica`; zmienisz go
przez `--base=`) i eksportuje pulę, więc dysk można od razu wypiąć:

```bash
./zfs-backup.sh prepare-media repl /dev/disk/by-id/<dysk> --yes
```

Taka pula pasuje do `--dst=repl/replica` z następnej sekcji.

`prepare-media` kończy się sprawdzeniem, że zwykłe `zpool import` wymienia nową pulę: czeka na udev, raz prosi
o ponowne odczytanie dysku i odmawia, jeśli puli nadal nie widać (bieg repliki wziąłby ten dysk za nieobecny).

Plan ostrzega, gdy jądro widzi mniejszy sektor fizyczny niż podaje dysk (`smartctl`).
Tak robi część mostków USB (512 B zamiast 4096 B); `ashift=12` i tak trzyma pulę w
wyrównaniu.

**Dysk USB: kolejka.** Dysk za sterownikiem `usb-storage` startuje z `nr_requests=2`;
zapisy ZFS nie są wtedy scalane i replika pisze ok. 10 MB/s (zmierzone 2026-11-09,
WD My Passport 2 TB). Dlatego bramka przed każdym importem puli, a `prepare-media` przed
założeniem puli, podnoszą `nr_requests` dysków USB do 128 (ten sam dysk: 57–65 MB/s).
Ustawienie ginie po odłączeniu dysku, więc jest powtarzane przy każdym podłączeniu.
Nigdy nie jest obniżane, a dysków innych niż USB nie dotyka.

Dwa dyski rotacyjne dostają **tę samą nazwę puli** i różne GUID-y. Bramka
rozpoznaje nośnik po GUID-zie, nie po nazwie, więc rotacja działa, a dwa dyski
podłączone naraz są **odmawiane** z nazwaniem obu.

## 5. Scenariusz A: replika na nośnik wymienny

Jedno polecenie, dowolna liczba źródeł — `--source` jest powtarzalne:

```bash
./zfs-backup.sh add-replica weekly \
    --source=hdd/backups/10.0.0.9 \
    --source=hdd/backups/10.0.0.8 \
    --dst=repl/replica \
    --install --yes
```

`add-replica` jest **upsertem**: to samo polecenie z inną listą źródeł zmienia
istniejące zadanie. Domyślny harmonogram (bez `--schedule` albo z
`--schedule=auto`) to wolna godzina nocna na tym hoście — 22, 23, potem 0–5, z
wolną minutą — raz na dobę, więc dwie repliki nie ruszają razem; istniejąca
replika zostaje przy swoim harmonogramie. Replika **nie jest lustrem online**:
nośnik jest zagrożony tylko wtedy, gdy jego pula jest zaimportowana, więc liczba
biegów **jest** ekspozycją.

**Co trzyma dysk** — trzy kształty, wybierane w kreatorze repliki (F6) albo flagami:

- **własna migawka, odbicie kolektora** (domyślnie; własna rodzina `replica_`): każdy bieg robi migawkę `replica_`
  i ją kopiuje, po czym nośnik gubi to, co zgubił kolektor (`-M`);
- **`--keep=N`**: nośnik trzyma własnych N najnowszych migawek `replica_`, niezależnie od kolektora (bez `-M`;
  dysk wkładany raz w miesiącu może mieć 12 stanów). Idzie tylko własna migawka repliki (`-i`, o ile nie ustawiono
  `history`). Gdy bieg używa `-i`, także kolektor trzyma tylko najnowszą własną migawkę `replica_` na nośnik
  (`snapget.sh --source-keep=1`): po udanej kopii kasuje starsze, a zakładka `#tgt-` niesie następny przyrost.
  Kasowane są tylko migawki, które oznaczył bieg dla tego właśnie nośnika (`zfsbackup:srckeep-owner`: cel i GUID
  puli, więc dwa dyski rotacyjne o tej samej nazwie puli to dwóch właścicieli) i które nośnik trzyma; migawka bez
  oznaczenia nigdy nie jest ruszana, a nieudane kasowanie to ostrzeżenie, nie nieudany bieg. Przy jawnym
  `history = all` albo `auto:N` na kolektorze nic nie jest kasowane;
- **`--passive`**: bez własnych migawek; przenosi te, które już są, więc dysk ma stan z chwili najnowszej z nich.
  Pierwsza kopia takiego odbicia niesie historię: najstarsza kwalifikująca się migawka w całości, potem każda
  następna do najnowszej. Replika założona wcześniej zostaje przy tym, co ma; uzupełnia ją dopiero F6, Enter, `e`,
  „Zacznij od nowa na tym dysku (pełna kopia)”. Replika pasywna pomija rodziny migawek jak relacja:
  `--exclude-family=A,B` (litery, cyfry, `_ . : -`) daje jej to samo `-E`; kreator ustawia
  `__replicate_,vzdump,__migration__` pasywnej replice, która ich nie ma, żeby kopia stała na własnych migawkach
  narzędzia, a nie na tych, które replikacja Proxmoksa przemianowuje co kilka godzin. `list-replicas --json`
  pokazuje tę listę jako `exclude_family`.

Uruchomienie poza harmonogramem:

```bash
./zfs-backup.sh run-replicas          # bezpieczne o każdej porze
./zfs-backup.sh list-replicas         # inwentarz + żywy stan nośnika
```

Opcjonalnie, **nie domyślnie**, wyzwalacz po podłączeniu dysku:

```bash
./zfs-backup.sh install-media-trigger --install
```

Do 1.0.15 ta reguła udev była zapisywana z łamaniem linii, a `systemd-udevd` ją
odrzucał („Invalid key/value pair”): wyzwalacz po podłączeniu nie działał. Od 1.0.16
reguła ma jedną linię, a `--install` nadpisuje starą. Po aktualizacji uruchom
polecenie raz jeszcze i sprawdź, że
`journalctl -u systemd-udevd | grep 90-zfs-replica` nie pokazuje „Invalid”.

Po włożeniu dysku i zwłoce (`replica.insert_wait`, domyślnie 60 s) ruszają tylko repliki,
których nośnikiem jest ten dysk: po GUID puli, gdy replika ma listę dysków, inaczej po nazwie
puli (reguła podaje urządzenie, `blkid` czyta z niego pulę; gdy nie odczyta ani nazwy, ani
GUID, nie rusza żadna replika, a w logu jest o tym jedna linia, od 1.0.18). Inny dysk ZFS (np. dopiero
co sformatowany, zanim kreator zapisze jego GUID) nie uruchamia repliki, która ma listę dysków (GUID), i nie daje alarmu;
w logu zostaje po jednej linii na pominiętą replikę. Reguła wywołuje `systemd-run --collect`, więc nieudany bieg nie
blokuje następnych włożeń. Regułę bez `--collect` kreator repliki odnawia w planie.

**Jeden bieg naraz.** Kopia, która jeszcze trwa, gdy przychodzi następne wyzwolenie (harmonogram albo ponowne
podłączenie), nie startuje drugi raz: nowy bieg kończy się kodem 75 i mówi, od kiedy kopia trwa, a jego detach nie
eksportuje dysku spod trwającej kopii. Kod 75 to pominięcie, nie błąd; monitor wieku zgłasza trwającą kopię jako OK
(WARNING po przekroczeniu wieku krytycznego). Bieg, który nie umie się zapisać, nie startuje: gdy bramka nie może
założyć blokady ani zapisać i odczytać rekordu biegu, attach kończy się kodem 2 przed jakimkolwiek importem, a detach,
który trafi na nieczytelny rekord, nie eksportuje puli (przy zaimportowanej puli pisze DO NOT UNPLUG). Kopia zabita
przez SIGTERM i tak eksportuje swój dysk.

**Pierwsza kopia, która się nie zmieści, jest odmawiana.** Przed zapisem bramka sumuje źródła, które nie mają jeszcze
kopii na nośniku, i porównuje sumę z wolnym miejscem nośnika; gdy brakuje, eksportuje dysk i odmawia z obiema
liczbami (kod 2, alert). `add-replica` i kreator repliki pokazują rozmiar pierwszej kopii w planie, przed Uruchom,
wraz z wolnym miejscem, gdy pula nośnika jest zaimportowana, oraz `!!!`, gdy się nie zmieści. Gdy przy zakładaniu
nowej repliki dysk jest już podłączony, kreator pyta, czy zacząć pierwszą kopię teraz (w tle, jak F7; stan jest
w F2).

Źródło repliki, którego nazwa zawiera `:` (`tank/data:part`), jest kopiowane jako dataset lokalny.

**F6 w GUI.** Kolumny: Replika, Typ (podłączony / odłączony / wewnętrzny), Zajęte (jak pełny jest nośnik, gdy jego
pula jest zaimportowana), Wykonana, Ostatni bieg, Harmonogram; `list-replicas --json` niesie `medium_size`
i `medium_alloc` w bajtach (puste, gdy pula nie jest zaimportowana). Trwająca kopia pokazuje `kopia trwa od …`
(`running_since`) zamiast ostatniego zakończonego biegu; dysk dopiero co włożony, którego kopia czeka
(`replica.insert_wait`), pokazuje `dysk podłączony, kopia za ~N s` (`insert_in`). F6 czyta listę ponownie przy
wejściu i co 15 s. W F4 dataset repliki bez żadnej migawki mówi `kopia trwa`, dopóki kopia biegnie, i `przerwana,
wznowi się`, gdy przerwany odbiór zostawił token wznowienia. Kreator repliki pokazuje przy każdym datasecie liczbę
migawek, a przy zerze uwagę, że replika pasywna go nie skopiuje.

## 6. Scenariusz A: co ląduje w configu

Relację zapisuje narzędzie — nie piszesz tego ręcznie. Jeden blok
`[relation:NAZWA]` niesie całą politykę relacji (poziomy, retencję i minuty
każdej ze stron), a sekcje relacji tylko na niego wskazują przez
`relation = NAZWA` i mówią, po której stronie leżą (`side`). Tak wygląda
relacja z jednym datasetem na kolektorze (skrót prawdziwego configu):

```ini
[relation:src-a]
	tiers = hourly, daily
	hourly.target_send_schedule = 1 * * * *     # wartości z szablonu; minuty
	hourly.prune_schedule = 21 * * * *          # każdego datasetu niżej
	…                                           # (.retain, .prefix, .monitor …)

[dataset:hdd/backups/10.0.0.9/hdd/dane]         # kopia u kolektora
	relation     = src-a
	side         = target
	send_schedule_hourly = 13 * * * *           # własna minuta tego datasetu
	send_schedule_daily = 23 1 * * *
	prune_schedule_hourly = 33 * * * *          # porządki KOPII: +20
	prune_schedule_daily = 43 1 * * *
	…                                           # src, pair_label, flags -- narzędzie

[prune:zfsbackup-kolektor@10.0.0.9:hdd/dane]    # porządki ŹRÓDŁA, po SSH
	relation     = src-a
	side         = source
	prune_schedule_hourly = 53 * * * *          # porządki ŹRÓDŁA: +40
	prune_schedule_daily = 3 2 * * *
```

Druga sekcja jest tą, o której najłatwiej zapomnieć: **backup tworzy snapshoty
także na źródle**, a bez jej ograniczenia pula źródła rośnie bez końca.

Config pisany ręcznie może zamiast bloku używać szablonów (`[template:]` +
`use_template`), ale wewnątrz bloku `[relation:]` szablonów nie wolno mieszać.
Relacje zakładane przez GUI (F3 Relacje) i CLI są zawsze zapisywane jako blok.

Replika ma własny config, bo biegnie jako **root**, a backupy jako konto
delegowane:

```ini
[replica:weekly]
	source    = hdd/backups/10.0.0.9,hdd/backups/10.0.0.8
	dst       = repl/replica
	schedule  = 12 23 * * *              # wolna godzina nocna, wybrana automatycznie
	prefix    = replica_
	media     = removable
	recursive = yes
```

## 7. Scenariusz A: co ląduje w harmonogramie

Siedem zadań, **siedem różnych minut** — trzy sloty na relację (tabela pokazuje
poziom godzinny), plus replika raz na dobę w nocy:

| minuta | zadanie | dotyka |
|---|---|---|
| `:13` | backup src-a | SSH do zrodlo-a |
| `:07` | backup src-b | SSH do zrodlo-b |
| `:33` | przycinanie kopii src-a | tylko dysk lokalny |
| `:27` | przycinanie kopii src-b | tylko dysk lokalny |
| `:53` | przycinanie **źródła** src-a | **SSH do zrodlo-a** |
| `:47` | przycinanie **źródła** src-b | **SSH do zrodlo-b** |
| wolna minuta, godzina nocna | replika (root) | import/eksport puli |

Minuta bazowa jest wybierana **raz, przy tworzeniu relacji**: start z sumy
kontrolnej nazwy relacji, potem pierwsza minuta, której host jeszcze nie używa.
Wynik trafia do sekcji. Kolejne sloty to `+20` (przycinanie kopii) i `+40`
(przycinanie źródła). Sekcje, które już istnieją, zachowują swoje minuty, więc
dodanie trzeciej relacji nie rusza istniejących linii.

Linia zadania wygląda tak:

```
13 * * * * /root/scripts/zfs-snapshot-all/zfs-job.sh "kolektor … backup (src-a-dane)" \
           --log=/root/scripts/cron.log --notify=/root/scripts/notify-fail.sh \
           --detail=8 -- /home/zfsbackup/zfs-snapshot-all/snapget.sh -m … 
```

Koperta (`ZFS-JOB BEGIN/END`, przechwycenie stderr, powiadomienie) siedzi w
`zfs-job.sh`, a **polecenie silnika zostaje widoczne** po `--`. Linię można
skopiować i uruchomić z ręki — zachowa się dokładnie tak, jak pod cronem. Powód
jest twardy: cron przyjmuje polecenie do **1000 bajtów**.

## 8. Scenariusz A: rotacja nośnika, czasy i statystyki

```bash
# dysk A podłączony, bieg nocny albo run-replicas — po biegu pula jest
# wyeksportowana i dysk można wyjąć
./zfs-backup.sh list-replicas     # 'available' = podłączony, nie zaimportowany
```

Po podłączeniu dysku B (inny GUID, ta sama nazwa puli) pierwszy bieg go **wciągnie**,
bo bramka porówna GUID z zapisem i stwierdzi, że to inny nośnik. Zapis trzyma
jedną linię na źródło:

```
guid=3717319648122292429
snap:hdd/backups/10.0.0.9=replica_<data>_<godzina>
snap:hdd/backups/10.0.0.8=replica_<data>_<godzina>
```

Pominięcie biegu wymaga **wszystkich** warunków naraz: ten GUID, każde źródło
ciche, każde źródło udowodnione na tym dysku. Gdy którykolwiek warunek nie jest
spełniony, bieg normalnie importuje pulę.

**Dwa dyski naraz są odmawiane**, z `rc=2` i nazwaniem obu:

```
REFUSING: 2 pools named 'repl' are available to import. Rotated media often
share a name, so this is two disks in at once. Unplug one, or import the one
you mean by its id and re-run -- this will not choose for you.
```

**Nośnik z cudzą linią też jest odmawiany.** Jeśli dysk niesie replikę relacji,
której już nie ma, a kolektor ma nową rodzinę snapshotów bez wspólnego przodka —
bramka nazwie obie rodziny i postawi wybór (inny `--dst` albo `zfs destroy -r` na
celu), zamiast sypać co noc błędem ZFS-a. „Brak wspólnego przodka” rozstrzyga GUID: dysk jest odmawiany tylko wtedy,
gdy żadna jego migawka nie dzieli GUID-u z migawką ani zakładką na źródle. Migawka przemianowana po którejkolwiek
stronie liczy się jako wspólna, tak samo migawka, którą retencja kolektora już usunęła, a jej zakładka została (dysk
dostaje wtedy przyrost od zakładki). Dowód, którego nie da się odczytać, nie prowadzi ani do odmowy, ani do rady
`zfs destroy`. Te same sprawdzenia (pochodzenie, wolne miejsce) idą, gdy pula była zaimportowana przed biegiem, przez
przerwany bieg naszego narzędzia albo przez operatora; przy odmowie import operatora zostaje zaimportowany. Drzewo
źródła, którego nie da się wylistować w całości, nie liczy się jako „brak nowych danych”, więc kopia nie jest na tej
podstawie pomijana.

Czasy i statystyki — dwa poziomy, oba już zapisywane:

```bash
# poziom zadania: pełna historia, para znaczników na bieg
grep "ZFS-JOB" /home/zfsbackup/cron.log

# poziom datasetu: tryb, czas, objętość, przepustowość
./zfs-backup.sh progress --json
```

Przykładowe pola (liczby poglądowe):

```
total_bytes = 1000000000   done_bytes = 400000000
wire_bytes  =  250000000   rate_bps   =  50000000
```

`done_bytes` to co silnik wepchnął w rurę, `wire_bytes` to co wyszło łączem —
przy kompresji łącze niesie mniej niż `done_bytes`, a różnica jest kompresją. `-1` znaczy „niemierzalne tutaj" (przy `push` mbuffer stoi
po stronie zdalnej), **nigdy 0**, żeby brak pomiaru nie czytał się jako bezczynne
łącze. Obserwator próbkuje **co 2 sekundy**, więc transfer krótszy niż tick
zostawia zera. Rekordy są sprzątane przy każdym biegu silnika — po 7 dniach, z
pominięciem tych w stanie `running`.

## 9. Scenariusz B: łańcuch pasywny, trzy hosty

```
źródło               serwer 1 (backup)             serwer 2 (dublet)
hdd/dane   ────────► hdd/kopie/<źródło>/… ───────► hdd/kopie/<źródło>/…
      ogniwo A: backup              ogniwo B: sync (pasywny)
```

Oba ogniwa są kolektorami: serwer 1 ciągnie ze źródła, serwer 2 ciągnie z
serwera 1. Konto zadań wybierasz osobno na każdym kolektorze (sekcja 2), flagą
`--local-user` przy tworzeniu danego ogniwa.

**Wymagania serwera 2.** Pula musi mieć **tę samą nazwę** co na serwerze 1
(sync odtwarza te same ścieżki). Jądro i nagłówki muszą do siebie pasować, bo
moduł ZFS jest budowany pod konkretne jądro. Kanał root-ssh z serwera 2 na
serwer 1 jest potrzebny tylko dla wariantu zdalnego (sekcja 1).

**Ogniwo A — backup, jedna komenda na serwerze 1:**

```bash
# na serwerze 1:
./zfs-backup.sh \
    --source=<źródło>:hdd/dane \
    --target=hdd/kopie \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

Weryfikacja ogniwa A: porównaj sumę kontrolną pliku na źródle i w kopii oraz
`guid` tego samego snapshotu po obu stronach — musi być identyczny:

```bash
# na serwerze 1:
zfs list -H -t snapshot -o name -r hdd/kopie/<źródło>/hdd/dane
zfs get -H -o value guid "hdd/kopie/<źródło>/hdd/dane@<snapshot>"
# na źródle ten sam snapshot:
zfs get -H -o value guid "hdd/dane@<snapshot>"
```

**Ogniwo B — dublet, jedna komenda na serwerze 2:**

```bash
# na serwerze 2:
./zfs-backup.sh \
    --source=<serwer1>:hdd/kopie/<źródło>/hdd/dane \
    --mode=sync \
    --local-user=zfsbackup \
    --grant-remotely --yes --install
```

`--mode=sync` to mapowanie tożsamościowe (ta sama ścieżka na dublecie — stąd
wymóg tej samej nazwy puli). Odmowę dostaniesz, jeśli serwer 1 wygląda na członka
tego samego klastra PVE co serwer 2: wewnątrz klastra replikuje już `pvesr`, więc
użyj tam `--mode=backup`.

Ponieważ źródło ogniwa B **już niesie rodzinę `automated_*`** (wytwarza ją ogniwo
A), relacja zostaje wykryta jako **PASYWNA**: `snapget -e` konsumuje najnowszy
istniejący snapshot, niczego na źródle nie tworzy i nie przycina — retencja rodziny
zostaje przy serwerze 1. Harmonogram pasywny to `:31` (pół godziny za
producentem), progi monitora 3h/5h (kadencja łańcucha). Podgląd aktywacji mówi o
pasywności wprost.

Ogniwo pasywne nigdy nie bierze migawki zarezerwowanej przez Proxmoksa (`__replicate_`, `vzdump`, `__migration__`)
za najnowszą ani za bazę, z `-E` czy bez; dataset mający tylko takie migawki jest odmawiany („Every source snapshot
on '<dataset>' matches an -E exclusion”), a przy `-R` pomijany jako rusztowanie. Poddrzewo bez żadnej migawki
(`-e -R`) nie jest nieudanym biegiem: mówi „nothing to copy” i kończy się kodem 0. Ogniwo B jest też lustrem
(`-M`): migawka przemianowana na źródle zostaje na dublecie, bo „zniknęła ze źródła” rozstrzyga GUID.

Weryfikacja końca łańcucha:

```bash
# na serwerze 2:
zfs mount hdd/kopie/<źródło>/hdd/dane        # kopie są noauto
```

Dowód przyrostu: dopisz plik na źródle, odczekaj bieg ogniwa A i bieg ogniwa B;
suma kontrolna nowego pliku musi być identyczna na trzech hostach. Przebiegi widać
w logu po markerach:

```bash
grep ZFS-JOB /home/zfsbackup/cron.log | tail    # BEGIN/END rc=… per przebieg
```

## 10. Rozbiórka — dokładnie odwrotnie

Jedna kolejność dla obu scenariuszy: najpierw to, co ciągnie najdalej od źródła
(replika, potem ogniwo B łańcucha), na końcu ogniwo przy źródle.

Na kolektorze (dla scenariusza A):

```bash
./zfs-backup.sh remove-replica weekly --install --yes
./zfs-backup.sh remove-client src-a
./zfs-backup.sh remove-client src-b
./clean-relationships.sh --purge-orphans --yes
zfs destroy -r hdd/backups          # DANE kasuje człowiek, nie narzędzie
```

Scenariusz B: najpierw `remove-client` na serwerze 2 (dublet przestaje ciągnąć,
zanim zniknie jego źródło) i `deploy.sh --leave` na serwerze 1; potem
`remove-client` na serwerze 1 i `deploy.sh --leave` na źródle.

Na każdym hoście będącym źródłem relacji, z jego własnej konsoli (etykieta =
krótki hostname kolektora):

```bash
./deploy.sh --leave=kolektor
./clean-relationships.sh            # ma zakończyć się „nothing orphaned"
```

`remove-client` usuwa sekcje z crontaba i rekord parowania kolektora. `--leave`
na źródle usuwa konto delegowane, granty `zfs allow`, manifest joina i pliki
zakresu. Jeśli `--leave` odmówi z powodu niedomkniętego `zfs unallow` (stary
grant ręczny), wykonaj wskazany w komunikacie `zfs unallow -u <uid> <dataset>` i
ponów to samo polecenie.

`remove-replica` na **ostatnim** zadaniu w configu zdejmuje cały blok zarządzany
i mówi o tym wprost. Żaden z tych czasowników nie kasuje datasetów ani kopii na
nośniku: „unpairing ends the relationship, not the backup".

`remove-replica --install` usuwa też pliki stanu repliki w
`/var/lib/zfs-snapshot-all/media/` (`<nazwa>.current`, `.synced`, `.last-seen` i rekordy
biegu), więc nowa replika o tej samej nazwie zaczyna od zera. Kopia, która właśnie biegnie,
jest wymieniona w planie i w oknie Del na F6 i nie jest przerywana: dobiega do końca, odłącza dysk i do tego
czasu zachowuje własne rekordy biegu.

**Kopii na nośniku pakiet nie kasuje** — nie ma na to osobnego czasownika. Dysk
czyści się formatowaniem: w GUI zmiana repliki -> „Dodaj dysk".

## 11. Pułapki

| pułapka | co robić |
|---|---|
| kolektor bez kanału root-ssh do produkcji | używaj `--manual-join` (sekcja 3); nie zakładaj stałego zaufania root→produkcja |
| brak `crontab` na świeżym hoście | zainstaluj crona; kontrola zależności to wykryje |
| strefa czasowa hosta inna niż reszta floty | ustaw ją (sekcja 1); aktywacja ostrzega o rozjeździe |
| dwa ogniwa łańcucha tworzące jedną rodzinę snapshotów | ogniwo B z istniejącej rodziny jest PASYWNE i niczego nie tworzy ani nie przycina; nie omijaj tego ręcznym configiem |
| konto delegowane dostaje **uwolniony UID** po poprzednim | `--leave` zabiera katalog bramki; audyt musi kończyć się „nothing orphaned" |
| ta sama nazwa relacji użyta ponownie | stary rekord ląduje jako `*.conf.removed-<ts>`; audyt je **wypisuje**, nie kasuje |
| linia crona blisko 1000 bajtów | koperta jest w `zfs-job.sh`; jeśli `crontab` odmówi, komunikat nazwie każde polecenie ponad limit z jego długością |
| harmonogram po reinstalacji | zawsze porównaj przed instalacją: regeneracja z configu vs żywy `crontab -l` |
| `--leave` odmawia przy niedomkniętym `zfs unallow` | wykonaj `zfs unallow` wskazany w komunikacie i ponów to samo polecenie |

Trzy strażniki zadziałają same, zgodnie z projektem: odmowa pełnego resendu bez
`-f`, odmowa instalacji kasującej joby i fail-closed `--leave` przy niedomkniętym
`unallow`.

## 12. Sprawdzenie końcowe

```bash
./zfs-backup.sh status              # każda relacja: state=active
./zfs-backup.sh list-replicas       # nośnik: here / available / away / wrong_medium
./clean-relationships.sh            # „nothing orphaned" na KAŻDYM z hostów
zfs list -r hdd/backups             # dane u kolektora
```
