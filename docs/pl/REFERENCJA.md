# zfs-snapshot-all: referencja techniczna

Wersja angielska: [REFERENCE.md](../en/REFERENCE.md).

To jest referencja poszczególnych programów, flag i sekcji configu.
Procedurę stawiania dwóch hostów znajdziesz najpierw w
[WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md); gotowe configi dla zaawansowanych są w
[PRZYKLADY-CONFIGU.md](PRZYKLADY-CONFIGU.md). Pełna lista czasowników `zfs-backup.sh` jest w
[KOMENDY.md](KOMENDY.md), a to, jak elementy do siebie pasują, opisuje
[JAK-TO-DZIALA.md](JAK-TO-DZIALA.md).

## Spis treści

- [Komponenty w skrócie](#komponenty-w-skrócie)
- [Drzwi wejściowe i GUI](#drzwi-wejściowe-i-gui)
  - [Rodzaje relacji](#rodzaje-relacji)
  - [Komendy według przeznaczenia](#komendy-według-przeznaczenia)
  - [GUI](#gui)
- [Podstawowe pojęcia](#podstawowe-pojęcia)
  - [Dopasowanie po GUID](#dopasowanie-po-guid)
  - [Przyrostowy fallback oparty na bookmarkach](#przyrostowy-fallback-oparty-na-bookmarkach)
  - [Transfery wznawialne](#transfery-wznawialne)
  - [Ochrona migawek w locie przez hold](#ochrona-migawek-w-locie-przez-hold)
  - [Identyfikatory zadań](#identyfikatory-zadań)
  - [Pomijanie migawek pośrednich](#pomijanie-migawek-pośrednich)
    - [Automatyczny próg nadrabiania](#automatyczny-próg-nadrabiania)
  - [Zamrażanie gości Proxmoxa](#zamrażanie-gości-proxmoxa)
  - [Autodostrajanie łącza](#autodostrajanie-łącza)
  - [Kompresja](#kompresja)
  - [Ograniczanie przepustowości](#ograniczanie-przepustowości)
  - [Montowanie celu](#montowanie-celu)
  - [Log statystyk JSON-lines](#log-statystyk-json-lines)
- [snapsend.sh (wysyłka)](#snapsendsh-wysyłka)
- [snapget.sh (pobranie)](#snapgetsh-pobranie)
  - [Tryby rekurencji](#tryby-rekurencji)
  - [Filtrowanie rozwinięcia](#filtrowanie-rozwinięcia)
- [delsnaps.sh (retencja i prune)](#delsnapssh-retencja-i-prune)
  - [Ochrona zarezerwowanych prefiksów](#ochrona-zarezerwowanych-prefiksów)
  - [Prune bookmarków](#prune-bookmarków)
  - [Drabina kaskadowa GFS](#drabina-kaskadowa-gfs)
- [check-snap-age.sh (strażnik świeżości)](#check-snap-agesh-strażnik-świeżości)
- [gen-cron.sh (generator crona sterowany configiem)](#gen-cronsh-generator-crona-sterowany-configiem)
  - [Opcje](#opcje)
  - [Bloki relacji: co zapisuje narzędzie](#bloki-relacji-co-zapisuje-narzędzie)
  - [Typy sekcji](#typy-sekcji)
  - [Ręcznie pisane configi z szablonami](#ręcznie-pisane-configi-z-szablonami)
  - [Co egzekwuje generator](#co-egzekwuje-generator)
  - [Sekcje prune tylko ze strażnikiem](#sekcje-prune-tylko-ze-strażnikiem)
  - [Drabina GFS w sekcji prune](#drabina-gfs-w-sekcji-prune)
- [Alerty](#alerty)
  - [Wybór rytmu](#wybór-rytmu)
  - [Kolejka, digest i skrypty notify](#kolejka-digest-i-skrypty-notify)
  - [Kondycja puli](#kondycja-puli)
  - [Rotacja logów](#rotacja-logów)
- [deploy.sh (przygotowanie hosta)](#deploysh-przygotowanie-hosta)
- [Przykłady z praktyki](#przykłady-z-praktyki)

Testy są opisane w [../../test/README.md](../../test/README.md).

## Komponenty w skrócie

| Program | Rola |
|---|---|
| [`zfs-backup.sh`](../../zfs-backup.sh) | Drzwi wejściowe. Tworzy, aktywuje, pauzuje, edytuje i usuwa relacje; uruchamia repliki; startuje GUI (`zfs-backup gui`). Orkiestruje programy poniżej i nigdy nie zapisuje na produkcyjnych danych klienta (to zadanie `zfs-restore.sh`) |
| [`zfs-restore.sh`](../../zfs-restore.sh) | Powierzchnia odzysku (planer, bezpieczny odzysk do osobnej przestrzeni nazw, destrukcyjne zastąpienie za wyraźną zgodą). `zfs-backup.sh restore` przekazuje do niego wywołanie |
| [`snapsend.sh`](../../snapsend.sh) | Tworzy migawkę i replikuje dataset wysyłką (źródło zawsze lokalne, cel lokalny lub zdalny) |
| [`snapget.sh`](../../snapget.sh) | Replikuje dataset pobraniem (cel zawsze lokalny, źródło lokalne lub zdalne); także tryb lustra i tryb samych migawek |
| [`delsnaps.sh`](../../delsnaps.sh) | Prune migawek (wg wieku, liczby lub drabiny GFS) oraz osieroconych bookmarków |
| [`check-snap-age.sh`](../../check-snap-age.sh) | Sprawdzenie świeżości w stylu Nagiosa: wiek najnowszej pasującej migawki, lokalnie lub przez ssh |
| [`gen-cron.sh`](../../gen-cron.sh) | Generuje (i opcjonalnie instaluje) blok crontaba z jednego configu INI |
| [`zfs-job.sh`](../../zfs-job.sh) | Koperta wokół każdego wygenerowanego zadania crona (logowanie, znaczniki początku i końca, powiadomienie o błędzie). Polecenie silnika pozostaje czytelne w linii crontaba |
| [`deploy.sh`](../../deploy.sh) | Stawia hosta (zależności, checkout, alarmowanie, rotacja logów, test dymny, opcjonalne konto delegowane) i obsługuje parowanie (`--pair`, `--join`, `--leave`) |
| [`clean-relationships.sh`](../../clean-relationships.sh) | Audytuje jednego hosta pod kątem śladów relacji (rekordy, konta, klucze, uprawnienia, holdy) i na polecenie usuwa martwe |
| [`update-control.sh`](../../update-control.sh) | Samoaktualizacja, rollback i wstrzymanie aktualizacji, wdrażane poza checkoutem, którym zarządzają |
| [`zfs-pair-gate.sh`](../../zfs-pair-gate.sh) | Bramka po stronie partnera, która odmawia poleceń płaszczyzny danych wyłączonej relacji |
| [`zfs-media-gate.sh`](../../zfs-media-gate.sh) | Klamra `zpool import`, sync, `zpool export` wokół repliki na nośnik wymienny |
| [`zfs-quiesce-helper.sh`](../../zfs-quiesce-helper.sh) | Jedyna uprzywilejowana czynność, jaką konto delegowane może wykonać na gościu (freeze/thaw), za regułą sudo |
| [`tui/`](../../tui) | Tekstowe GUI (`zfs-tui.py` plus okna whiptail, które uruchamia) |
| [`hostscripts/`](../../hostscripts) | Skrypty, które host uruchamia z crona lub do alarmowania, instalowane przez kopiowanie: `notify-fail.sh`, `notify-warn.sh`, `alert-digest.sh`, `alert-env.sh`, `check-pool-capacity.sh`, `capacity-guard.sh`, `growth-guard.sh` |
| `lib-*.sh` | Wspólny kod, ładowany przez source i nigdy nie uruchamiany: [`lib-zfs-snap.sh`](../../lib-zfs-snap.sh) (silnik send/receive/quiesce dla snapsend i snapget), `lib-cron.sh` (jedyny zapisujący crontab), `lib-backup-common.sh`, `lib-pairing.sh`, `lib-scope.sh`, `lib-profile.sh`, `lib-record.sh`, `lib-rekey.sh` |
| [`profiles/`](../../profiles) | Szablony retencji; zobacz [profiles/README.md](../../profiles/README.md) |

Wersji tu nie podajemy, bo numer utrzymywany ręcznie w dwóch miejscach się starzeje. Zapytaj
program: `snapsend.sh`, `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh` i `gen-cron.sh` odpowiadają
na `-V`; `deploy.sh` i `zfs-backup.sh` odpowiadają na `--version` (rewizja checkoutu). Changelogiem
jest `git log`; ten dokument opisuje wyłącznie bieżące zachowanie.

## Drzwi wejściowe i GUI

Zwykle nie wywołujesz silników sam. `zfs-backup.sh` tworzy relację, zapisuje config, instaluje
blok crona i pilnuje spójności elementów. Uruchom go bez argumentów, żeby wypisać pełny opis
użycia. Relację tworzy się czterema komendami (kolektor, źródło, kolektor, kolektor), jak pokazano w
[WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md); każdą komendę można uruchomić ponownie po
przerwaniu i wznawia ona pracę od trwałego stanu.

### Rodzaje relacji

Takich nazw używa GUI.

| Rodzaj | Co robi | Silnik |
|---|---|---|
| backup | Kolektor pobiera datasety źródła do własnego celu i trzyma warstwową historię po obu stronach | `snapget.sh`, `delsnaps.sh` |
| lustro (mirror) | Tryb sync: kolektor trzyma datasety źródła pod tymi samymi ścieżkami i po każdym pobraniu niszczy migawki celu, których źródło już nie ma (`snapget.sh -M`) | `snapget.sh -M` |
| kopia lokalna (local copy) | Kopia lokalnych datasetów na inną lokalną pulę, uruchamiana przez roota lub wskazane konto | `snapget.sh` z lokalnym źródłem |
| migawki lokalne (local snapshots) | Migawki na źródle, prune w miejscu, nic nie jest kopiowane (`--target=''`) | `snapsend.sh`, `delsnaps.sh` |
| migawki zdalne (remote snapshots) | Kolektor robi migawki na zdalnym źródle i niczego nie kopiuje (sekcja `[snaponly:]`, `snapget.sh -s`) | `snapget.sh -s`, `delsnaps.sh` |

Wysyłka zdalna (źródło wysyła do kolektora) to tryb CLI dla istniejących flot; GUI nie ma dla niej
okna. Zobacz [snapsend.sh](#snapsendsh-wysyłka).

### Komendy według przeznaczenia

| Cel | Czasowniki |
|---|---|
| Tworzenie | `--source=HOST:DATASET --target=DATASET [--install]` (zdalny backup; bez `--install` tylko planuje), `--mode=sync` (lustro), `--source=DATASET --target=DATASET` (kopia lokalna), `--target=''` (migawki lokalne), `new-relation` (kreator), `add-client`, `seed`, `activate` |
| Zmiana | `edit-relation`, `set-tiers`, `show-tiers`, `set-transfer`, `set-bandwidth`, `add-source`, `remove-source`, `save-profile`, `list-profiles`, `delete-profile`, `edit-config` |
| Stan | `pause-client` / `resume-client` (pauza logiczna, `-L` w liniach zadań), `disable-client` / `enable-client` (partner odmawia relacji), `move-to-client`, `set-endpoint`, `verify-endpoint`, `final-catchup` |
| Usuwanie | `remove-client`, `delete-relation` (całe usunięcie jedną komendą) |
| Podgląd | `status`, `monitor`, `list-jobs`, `job-stats`, `show-config`, `show-scope`, `pair-snapshots`, `export-relation` / `import-relation`, `list-datasets`, `check-source`, `source-pruners`, `prepare-source`, `test` |
| Repliki (dodatkowe kopie na dyski, które się odłącza) | `add-replica`, `list-replicas`, `run-replicas`, `run-relation`, `prepare-media`, `install-media-trigger`, `remove-media-trigger`, `replica-restart`, `remove-replica` |
| Odzysk | `restore --plan`, `restore --dataset=D --snapshot=S` (bezpieczny odzysk obok), `browse NAME --ask` (montowanie migawki tylko do odczytu, kopiowanie plików) |

Czasowniki kończące się na `-client` działają na rekordzie relacji; czasowniki bez tej końcówki
działają na łączu lub na danych. Wiele czasowników tylko planuje, dopóki nie podasz `--yes` (albo
`--install`), a czytniki mają formę `--json`, która jest warstwą danych GUI.

### GUI

`zfs-backup gui` (równoważnie `./zfs-backup.sh gui`) otwiera pełnoekranowy interfejs tekstowy dla
sesji ssh. To cienka warstwa nad powyższymi czasownikami: czyta ich wyjście `--json` i uruchamia te
same komendy, więc wszystko, co robi, da się zrobić z linii poleceń. GUI startuje po angielsku;
po polsku: F10 Ustawienia, pozycja `language` (zapisuje `[gui] language = pl` w `settings.ini`);
jednorazowo: `ZFS_TUI_LANG=pl zfs-backup gui` albo `--lang=pl`.

| Klawisz | Okno lub akcja |
|---|---|
| F1 | Pomoc |
| F2 | Przebiegi (co biegło i co pobiegnie) |
| F3 | Relacje (Ins = nowa, Del = usuń, Enter = otwórz, `e` = edytuj w oknie relacji) |
| F4 | Kopie (Enter/Tab do migawek, Enter na migawce albo F7 przegląda pliki, F9 przywraca) |
| F5 | Szablony |
| F6 | Replika |
| F7 | Uruchom teraz (F2, F3, F6), Przeglądaj (F4) |
| F8 | Pokaż/schowaj wykonane (F2), pauza/wznów na relacji (F3), Grupuj po relacji (F4), Klucz (F6) |
| F9 | Grupuj po relacji (F2), Plik -- eksport/import (F3), Przywróć (F4) |
| F10 | Ustawienia (`settings.ini` hosta, zobacz [Alerty](#alerty)) |
| F12 | Wyjście |

Odzysk z dysku (dawne okno F11 Odzysk) jest od 2026-10-27 w F4 Kopie: wiersz dysku, F9. F11 jest wolne.

## Podstawowe pojęcia

To są idee, przez które zestaw zachowuje się inaczej niż naiwna nakładka na `zfs send | zfs recv`.
Przejdź do [Scenariuszy roboczych](#przykłady-z-praktyki), żeby zobaczyć je w akcji.

### Dopasowanie po GUID

`find_common_snapshot()` najpierw próbuje dopasować migawki źródła i celu **po nazwie** (szybka
ścieżka). Jeśli nic nie pasuje, bo od ostatniej synchronizacji po którejś stronie zmieniono nazwę
migawki albo samego datasetu, przechodzi na dopasowanie **po GUID-zie ZFS**, czyli właściwości
identyfikującej migawkę niezależnie od jej obecnej nazwy. `zfs receive` wyznacza przyrost według
osadzonego w strumieniu `fromguid`, a nie według nazwy podanej w `-i`/`-I`, więc nazwa po stronie
źródła znaleziona przez GUID jest prawidłową bazą przyrostu.

Bez tego zmieniona nazwa migawki wymusza pełne ponowne wysłanie (a z `-f` destrukcyjny rollback
celu). Z tym replikacja przeżywa sytuację, gdy admin zmieni nazwę migawki dla czytelności albo
zrobi `zfs rename` samego datasetu.

### Przyrostowy fallback oparty na bookmarkach

Bookmark ZFS (`dataset#mark`) zapamiętuje txg i GUID migawki praktycznie bez kosztu miejsca. To
wystarcza, by posłużył jako baza przyrostowego wysyłania, ale nie jest migawką i nie można do niego
odbierać. Po każdym udanym, nierekurencyjnym transferze `record_send_bookmark()` odświeża **jeden**
bookmark na cel w datasecie **źródła**, zastępując poprzedni. Jeśli migawka, na której ten bookmark
się opierał, zostanie później usunięta ze źródła (przez `delsnaps.sh`, zanim cel nadrobił), to
`find_bookmark_base()` w następnym przebiegu nadal znajdzie prawidłową bazę przyrostu przez
bookmark, zamiast spadać do pełnego wysłania.

Nazwy bookmarków mają postać `tgt-<8 znaków hex>`: to skrót ścieżki datasetu celu (oraz
identyfikatora `-j`, jeśli jest). Nic innego na źródle ich nie rusza, więc dokładnie jeden bookmark
na parę (cel, identyfikator) się kumuluje, aż cel zostanie wycofany; o ich sprzątaniu zobacz
[Prune bookmarków](#prune-bookmarków). Przy `-r` (jeden atomowy strumień) silniki nie trzymają
żadnego bookmarka.

### Transfery wznawialne

Jeśli `zfs receive` zostanie przerwany w środku strumienia, ZFS zostawia na celu
`receive_resume_token`. Oba silniki go wykrywają i wznawiają przez `zfs send -t <token>` zamiast
zaczynać od nowa, maksymalnie `MAX_RESUME_ATTEMPTS` (3) razy, liczone na cel w `LOCKDIR`. Po tylu
nieudanych wznowieniach `zfs receive -A` porzuca stan częściowy (nie istniejącą historię celu),
a następny przebieg wraca do zwykłego wysłania przyrostowego lub pełnego.

### Ochrona migawek w locie przez hold

Migawka, którą czyta `zfs send`, albo od której wciąż zależy zablokowany token wznowienia, jest
chroniona przez `zfs hold` (tag `zfssnapall_inflight`). Egzekwuje to sam ZFS: `delsnaps.sh`
uruchomiony w tym samym oknie crona nie może usunąć migawki, która jest w trakcie transferu, bo
`zfs destroy` na migawce z holdem kończy się błędem. `delsnaps.sh` rozpoznaje ten hold i zgłasza
„in-flight, skipped” zamiast ogólnego błędu obiektu zależnego. Hold jest zdejmowany, gdy tylko
transfer się uda albo zakończy błędem bez tokenu wznowienia do ochrony.

Hold zakładany jest zaraz po migawce, przed utworzeniem celu, więc tworzenie przodków, tworzenie
celu, odmowa wymuszonego pełnego wysłania i listowanie migawek celu odbywają się, gdy hold trwa.
Każda z tych ścieżek błędu zdejmuje hold przy wyjściu: porzucony hold uczyniłby migawkę źródła
nieusuwalną, a `zfs destroy` zgłaszałby tylko mylące `dataset is busy`. Wyjątkiem jest celowo
ścieżka błędu transferu, bo przy tokenie wznowienia późniejszy przebieg potrzebuje właśnie tej
migawki.

**Wyjątek: datasety replikowane przez Proxmox VE nigdy nie dostają holda.** Jeśli dataset ma
jakąkolwiek migawkę `@__replicate_`, hold jest pomijany, a powód logowany. `pvesr` przenosi dane
przez `zfs send -Rpv | zfs recv -F`, a wymuszony odbiór strumienia replikacji niszczy każdą migawkę
celu, której strona wysyłająca już nie ma. Migawki z holdem nie da się zniszczyć, więc odbiór by
się przerwał, a replikacja pozostałaby zepsuta, dopóki ktoś nie zdejmie holda ręcznie. Uważaj na
migawki o nazwie `recv-<pid>-1`: tak wymuszony odbiór traktuje migawkę celu, której nie udało mu
się usunąć.

Pominięcie niczego nie kosztuje. Hold istnieje, by `delsnaps.sh` nie robił prune w trakcie
wysyłania, ale w datasecie zarządzanym przez `pvesr` zbiór migawek nie jest twoim do obrony, bo
`pvesr` przepisuje go przy każdej synchronizacji, żeby odbijał źródło. Test nie odróżnia źródła
replikacji od celu i nie próbuje; skłanianie się ku „pomiń” wymienia odrobinę ochrony przed prune
na to, że replikacja nigdy się nie zablokuje.

### Identyfikatory zadań

Oba silniki domyślnie kluczują blokadę pojedynczej instancji i tag bookmarka wyłącznie po
`(źródło, cel)`, więc ręczne i zaplanowane uruchomienie tego samego zadania zawsze ustawiają się w
kolejce zamiast się ścigać. `-j <TAG>` wplata dodatkowy tag w oba, dzięki czemu **drugie,
niezależne zadanie** wycelowane w tę samą parę źródło/cel ma własną blokadę i własny bookmark
bazy przyrostu. Pomiń go, żeby zachować domyślne zachowanie.

```bash
# Two schedules hitting the same target, deliberately kept independent:
./snapsend.sh -e -j hourly  tank/data backup/tank/data
./snapsend.sh -e -j offsite tank/data backup/tank/data
```

### Pomijanie migawek pośrednich

Gdy znaleziono wspólną bazę, przyrost normalnie wykonuje `zfs send -I <baza> <najnowsza>`, co
przenosi **każdą** migawkę pomiędzy jako osobną migawkę na celu. Dzięki temu rzadszy szczebel
(dzienny, tygodniowy, ...) jedzie na przyroście zadania godzinowego do archiwum. `-i` przełącza to
jedno wysłanie na `zfs send -i <baza> <najnowsza>`: tylko różnica do najnowszej migawki, żadnej z
pośrednich.

Jest to przeznaczone dla celu, który długo był offline: przy domyślnym zachowaniu każda
godzinowa/dzienna/itd. migawka zrobiona pod jego nieobecność ląduje na celu i jest przesyłana w
całości; `-i` przenosi tylko stan końcowy, w jednym kroku. Cena jest taka, że cel nie zyskuje
własnej historii migawek pośrednich.

Łączy się z `-r`: `zfs send -R -i` jest prawidłowe i rekurencyjne, więc baza i najnowsza migawka
lądują w każdym datasecie poddrzewa, a pośrednie w żadnym. Przy `-R` (niezależne zadania per
dataset) każdy rozwinięty dataset ma własne szukanie wspólnej bazy, więc `-i` po prostu przełącza
ten wybór per dataset. Nie robi nic (jest zalogowane, nie odrzucone), gdy na początku nie ma
żadnej wspólnej migawki: ścieżka fallbacku bookmarkowego i tak wysyła pojedynczą różnicę.

```bash
# Target has been offline for a week; catch it up in one step instead of
# replaying every hourly/daily snapshot taken in the meantime:
./snapsend.sh -i tank/data backup/tank/data
```

#### Automatyczny próg nadrabiania

`-T <N>` rozstrzyga o `-i` automatycznie, per dataset, na podstawie tego, jak długo cel zalega,
wyrażonego **względem własnej kadencji migawek tego datasetu**, a nie jako bezwzględny czas czy
liczba. Próg bezwzględny tworzy arbitralny klif (23 h offline zachowuje każdą pośrednią, 26 h żadnej)
i jest błędny między szczeblami (zadanie godzinowe gromadzi około 24 migawek na dobę, dzienne
około jednej). Z `-T` próg brzmi „więcej niż N WŁASNYCH interwałów tego datasetu”, gdzie interwał
jest *zmierzony* (odstęp między dwiema najnowszymi migawkami na źródle pasującymi do prefiksu `-m`
tego przebiegu, nigdy zakładany).

| własna kadencja datasetu | własny interwał (zmierzony) | klif `-T 24` przy |
|---|---|---|
| godzinowa | ~1 h | ~24 h offline |
| dzienna | ~24 h | ~24 dni offline |

Dataset ze szczebla dziennego, offline od 5 dni, zostaje więc poniżej progu `N=24` i dalej wysyła
każdą migawkę dzienną, a dataset godzinowy offline od 26 godzin przekracza go i nadrabia jedną
różnicą.

```bash
./snapsend.sh -T 24 tank/data backup/tank/data
```

Przypadki niemierzalne (mniej niż dwie pasujące migawki na źródle, interwał zerowy lub ujemny,
wspólna migawka, której czasu utworzenia nie da się odczytać) zawsze rozstrzygają się na „nie”:
domyślne `-I` zostaje nietknięte, a `-T` nigdy nie wywala przebiegu. Jawne `-i` wygrywa bez
dyskusji i pomija sprawdzenie.

**Znane ograniczenie:** zadanie, którego prefiks `-m` pasuje naraz do kilku szczebli (na przykład
`-e -m automated_` pasujące do migawek godzinowych, dziennych, tygodniowych, miesięcznych i
rocznych), mierzy swój interwał z najczęstszego szczebla wśród dopasowań, co zaniża interwał dla
rzadszych szczebli jadących razem. Żeby tego uniknąć, używaj prefiksu `-m` jednego szczebla na
zadanie.

### Zamrażanie gości Proxmoxa

`-q <tryb>` zamraża gościa Proxmoxa, do którego należy dataset, tuż przed zrobieniem jego migawki,
dzięki czemu migawka jest spójna na poziomie systemu plików, a nie tylko spójna po awarii
(crash-consistent). Właściciel-gość jest wnioskowany z nazewnictwa datasetów Proxmoxa
(`vm-<id>-disk-N`, `subvol-<id>-disk-N`); wszystko inne dostaje migawkę normalnie, bez próby
zamrażania.

| tryb | mechanizm | dotyczy |
|---|---|---|
| `no` (domyślny) | nic | nikogo |
| `agent` | `qemu-guest-agent` `fsfreeze` | VM |
| `sync` | `pct exec <id> -- sync` (zrzut buforów, nie zamrożenie: kontenery nie mają agenta gościa, a ZFS nie implementuje `FIFREEZE`) | kontenery |
| `auto` | wybiera per gość wg jego typu | oba |

Okno zamrożenia zawiera **wyłącznie** `zfs snapshot`, nigdy transfer. Gość z kilkoma dyskami jest
zamrażany raz na przebieg, a wszystkie jego dyski dostają migawkę razem w jednym atomowym oknie.
`zfs snapshot` przyjmuje kilka nazw tylko w obrębie jednej puli, więc datasety rozłożone na kilka
pul dostają jedno atomowe wywołanie na pulę; każdy gość pozostaje zamrożony do powrotu ostatniego
wywołania, więc wszystkie dyski nadal lądują w tej samej chwili. Odmrożenie gwarantuje pułapka
`EXIT`. Zamrażanie jest ignorowane razem z `-e` (nic nowego nie powstaje) i z `-n`.

**Budżet okna.** VSS ogranicza zamrożenie Windowsa do około 10 sekund i zwalnia je samodzielnie,
więc udane `fsfreeze-freeze` niczego nie dowodzi w chwili, gdy działa `zfs snapshot`. Silnik
zamraża VM-y dopiero tuż przed migawką (powolna, niezamrażająca praca, jak zrzut buforów
kontenerów, odbywa się wcześniej), tuż przed `zfs snapshot` pyta każdą VM jeszcze raz, czy nadal
jest zamrożona, i mierzy czas od pierwszego zamrożenia. Gość, który już nie jest zamrożony, albo
okno dłuższe niż budżet (`QUIESCE_MAX_WINDOW`, domyślnie 5 sekund), powoduje odmowę zrobienia
migawki, zamiast robić ją na zamrożeniu, które mogło już zniknąć. Zwiększaj budżet tylko wtedy,
gdy wiesz, że dane goście utrzymają zamrożenie.

**Polityka błędu.** Nieudane zamrożenie nadal robi migawkę, spójną po awarii, chyba że szczebel
mówi `,strict`:

- nazwa migawki zawiera `_crash_` między rodziną a znacznikiem czasu
  (`automated_daily_crash_2026-08-26_20-50-40`), więc nadal należy do tej samej rodziny dla
  retencji i monitoringu;
- przebieg kończy się kodem **8**, więc notyfikator crona to zgłasza;
- log mówi, które zamrożenie się nie powiodło i dlaczego.

Dopisz `,strict` (`-q auto,strict`), żeby nie robić migawki i zamiast tego zakończyć przebieg
błędem; użyj tego dla datasetów, w których kopia spójna po awarii jest bezużyteczna, na przykład
baza danych, której procedura odzysku zaczyna się od jej odrzucenia. `,degrade` nadal jest
przyjmowane i prosi o to, co teraz jest domyślne. Niektóre błędy są w obu przypadkach fatalne:
odmrożenie, które się nie udało, obce zamrożenie już istniejące i rollback, który nie mógł usunąć
własnych migawek tego przebiegu. Parser kwalifikatorów jest wspólny dla obu silników;
`no,<kwalifikator>` jest odrzucane.

**Pobranie.** `snapget.sh -q` przyjmuje te same tryby i kwalifikatory, a cała sekwencja
zamrożenie, atomowa migawka, odmrożenie biegnie w jednym zdalnym wywołaniu z własną pułapką
`EXIT` i odłączonym licznikiem deadman (`-Q <SEKUNDY>`, domyślnie 120, minimum 10), więc zerwane
połączenie lub zabite lokalne zadanie nie zostawi gościa zamrożonego. Potrzebuje uprawnień na
źródle: sparuj z `--as=root` albo zostaw konto delegowane i uruchom na źródle
`deploy.sh --join <pakiet> --allow-quiesce`, co instaluje `zfs-quiesce-helper.sh` i regułę sudo
dla tego jednego skryptu. Gdy nie zrobisz żadnego z tych dwóch, obowiązuje domyślna polityka
degradacji: migawka `_crash_` i kod wyjścia 8 (zobacz wyżej); z `,strict` zadanie kończy się
błędem bez migawki. Źródło lokalne zamraża gości na tym hoście.

Spójność systemu plików to nie spójność aplikacji. Dla migawki spójnej z bazą danych umieść własną
logikę zamrażania silnika bazy (`FLUSH TABLES WITH READ LOCK`, tryb backupu Postgresa, ...) w
`/etc/qemu/fsfreeze-hook` gościa, który agent uruchamia wewnątrz zamrożenia.

### Autodostrajanie łącza

`-A` mierzy prawdziwą próbkę `zfs send` z datasetu (potrzebuje istniejącej migawki i cicho się
wycofuje przy pierwszym przebiegu datasetu) oraz prędkość łącza do hosta celu, po czym decyduje,
czy kompresja strumienia opłaca się dla *tych* danych na *tym* łączu. Pomiary są buforowane przez 7
dni (prędkość łącza per host; współczynnik per dataset, bo kompresowalność należy do danych), więc
sonda trwająca około 10 sekund odpala najwyżej mniej więcej raz w tygodniu; ponowny pomiar
wymusisz przez `ZFS_SNAP_RETUNE=1`. Jawne `-z`/`-Z`/`-g`/`-N` zawsze wygrywa: `-A` uzupełnia tylko
decyzję, której nie podjąłeś. Tylko transfery zdalne; cel lokalny nie ma czego mierzyć. W
pobraniu kompresor działa na zdalnym źródle, więc tam jest mierzony współczynnik.

### Kompresja

Dwa niezależne mechanizmy:

- **Jawna kompresja strumienia**: `-z`/`-Z` (zstd), `-g` (pigz), `-l <poziom>`. Wobec zdalnego
  celu lub źródła kompresja jest domyślnie włączona (zstd poziom 3), chyba że podasz `-N`. Przy
  transferze lokalnym jest ignorowana, z linią w logu i nigdy fatalnie, bo nie ma łącza sieciowego,
  wobec którego opłaciłby się koszt CPU. zstd jest domyślny, bo na sprzęcie referencyjnym wypadł
  jednoznacznie lepiej niż pigz (współczynnik około 2,3x przy mniej więcej 450 MB/s dla zstd -3,
  wobec około 2,2x przy mniej więcej 140 MB/s dla pigz -6).
- **Skompresowane wysyłanie** (`zfs send -c`), automatyczne i bez flagi: wysyła rekordy tak, jak już
  leżą na dysku, zamiast dekompresować do zbudowania strumienia i kompresować ponownie przy odbiorze.
  Nie kosztuje dodatkowego CPU (odejmuje pracę), więc w odróżnieniu od `-z` pomaga także przy
  czysto lokalnym transferze. Jest automatycznie pomijane, gdy pula celu nie ma wymaganych funkcji
  (`feature@lz4_compress`, a dla rekordów skompresowanych zstd także `feature@zstd_compress`);
  zwykłe wysyłanie wymusisz przez `ZFS_SNAP_NO_COMPRESSED_SEND=1`.

### Ograniczanie przepustowości

`-b <TEMPO>` ogranicza transfer. TEMPO to specyfikacja tempa mbuffera: zwykła liczba **bajtów** na
sekundę albo liczba z przyrostkiem `b`/`k`/`M`/`G` (w mnożnikach 1024). Bajty, nie bity: łącze 20
Mbps to `-b 2M`. Domyślnie brak limitu.

Jest stosowane jako `mbuffer -r` do mbuffera, który i tak jest w każdym potoku, więc nie kosztuje
dodatkowego procesu ani pamięci. Ten mbuffer stoi po stronie odbierającej, zaraz za łączem i
*przed* jakąkolwiek dekompresją, czyli dokładnie tam, gdzie liczone bajty to bajty przechodzące
przez łącze, skompresowane czy nie. Mechanizm to przeciwciśnienie: mbuffer opróżnia strumień w
tempie TEMPO, przestaje czytać z gniazda, TCP zamyka okno, a nadawca blokuje się. Bufory przed nim
(własne 16 MB mbuffera, okno TCP, bufory ssh) pozwalają początkowym chwilom transferu wyprzedzić
limit o dziesiątki MB, co nie ma znaczenia przy czymkolwiek, co warto dławić.

Zmierzone na niekompresowalnym strumieniu 200 MB między dwoma hostami:

| | bez limitu | `-b 20M` | `-b 5M` |
|---|---|---|---|
| wysyłka (`snapsend.sh`) | 6,7 s | 14,1 s | 44,9 s |

Oba wyniki z limitem to czas transferu wynikający z limitu plus około 4 s stałego narzutu.

Przy transferze **lokalnym** nie ma łącza, ale limit nadal działa i dławi I/O między pulami, żeby
duży backup nie zagłodził gości. `-b` zasila też [`-A`](#autodostrajanie-łącza): decyzja zapada
względem `min(zmierzone, -b)`; limit jest stosowany przy wejściu do decyzji i nie jest zapisywany
w buforze.

Gdy parowanie tworzone jest z `--bandwidth=TEMPO`, limit należy do łącza (każda relacja z tym
partnerem); zmienia go `zfs-backup.sh set-bandwidth`.

### Montowanie celu

**Cel replikacji nie jest montowany.** To ustawienie domyślne; `-u` nadal jest przyjmowane i nic
nie robi, żeby istniejące linie crona się parsowały, a `-U` przywraca montowanie dla celu, który
ma być przeglądany.

Powodem nie jest porządek. Zwykły `zfs send` nie niesie właściwości, więc odebrany dataset dziedziczy
`mountpoint` po nowym rodzicu i ląduje nieszkodliwie pod celem. Ale `-r` i `-H` wysyłają
**strumień replikacji** (`zfs send -R`), który *niesie* właściwości, a źródło z lokalnie ustawionym
punktem montowania przynosi tę ścieżkę ze sobą:

```
# source: tank/mptest, mountpoint=/mnt/mptest_live (local)
# received with mounting enabled, then:
$ findmnt -n /mnt/mptest_live
/mnt/mptest_live tank/mptest                zfs rw,relatime,xattr,noacl
/mnt/mptest_live backup/dst/tank/mptest     zfs rw,relatime,xattr,noacl   <- the BACKUP, on top
```

Kopia zapasowa montuje się **nad** żywym datasetem i go przysłania: wszystko, co czyta tę ścieżkę,
czyta teraz backup. `rpool/ROOT/pve-1` ma lokalnie ustawione `mountpoint=/` na każdym hoście
Proxmoxa, więc ten sam mechanizm przy rekurencyjnym backupie tego datasetu celuje w `/`. Dwa
mniejsze powody: zamontowana kopia rootfs każdego kontenera jest przeglądana przez wszystko, co
skanuje system plików, a odbiorca bez roota w ogóle nie może montować (`mount(2)` wymaga
`CAP_SYS_ADMIN` niezależnie od `zfs allow`).

| sytuacja | wynik |
|---|---|
| cel utworzony przez te programy | `canmount=noauto`, nigdy niemontowany (każdy poziom ścieżki celu, nie tylko liść) |
| odbiór przyrostowy do zamontowanego celu | pozostaje zamontowany; `-u` rządzi chwilą odbioru, a przyrost nie montuje ponownie |
| odbiór pełny/początkowy do istniejącego zamontowanego celu | zostawiony niezamontowany |
| `-w`/`-f`, gdzie `recv` buduje liść ze strumienia | zostawiony niezamontowany |
| potomkowie odebrani przy `-r` | zamykani (`canmount=noauto`) po udanym transferze rekurencyjnym; tylko systemy plików; pomijane przy `-U` |

`canmount` na istniejącym wcześniej celu nigdy nie jest przepisywane, więc `zfs mount <dataset>`
przywraca którykolwiek z nich ręcznie. `-U` ustawia `canmount=on` dla celów, które tworzy, bo
`canmount=noauto` w przeciwnym razie przebiłoby flagę recv i uczyniło opt-out bezsilnym. Własny
`canmount` źródła nie jest nigdy ruszany. Potomkowie strumienia rekurencyjnego są tworzeni przez
sam `zfs recv` i przychodzą z `canmount` źródła; silniki zamykają potem odebrane poddrzewo, żeby
zagrożenie przysłonięcia montowaniem nie sięgało też ich.

### Log statystyk JSON-lines

Każdy przebieg dopisuje jeden obiekt JSON na linię do `STATS_LOG` (JSON-lines: jeden rekord na
linię, bez tablicy na najwyższym poziomie), więc możesz go odpytywać przez `jq` zamiast parsować
regexem. Domyślna ścieżka to `/root/scripts/zfs-snapshot-stats.log` dla roota i
`$HOME/zfs-snapshot-stats.log` dla konta bez roota.

```json
{"time":"2026-07-24T10:15:03Z","script":"snapsend.sh","label":"src-a","dataset":"tank/data","target":"backup/tank/data","status":"success","duration_s":42,"resumed":false}
{"time":"2026-07-24T10:16:01Z","script":"delsnaps.sh","dataset":"tank/data","pattern":"auto_","status":"success","duration_s":1,"deleted":2,"kept":3}
```

Rekordy `snapsend.sh`/`snapget.sh` niosą `label` (relację, z `-L`; pusty, gdy zadanie jej nie ma),
`target` i `resumed` (prawdziwy boolean). Rekordy `delsnaps.sh` niosą zamiast tego
`pattern`/`deleted`/`kept`, bo robi prune, a nie transfer. `status` to `success`, błąd albo
odrębny niesukces, jak `skipped_paused` (relacja jest spauzowana), `skipped_lock` lub
`snapshot_only`, dzięki czemu pominięty przebieg nigdy nie zostanie odczytany jako świeży backup.
Logowanie jest typu best-effort: niezapisywalna ścieżka jest połykana, zamiast wywalać backup,
który już się udał.

```bash
# Every non-success record since yesterday:
jq -c --arg since "$(date -u -d '1 day ago' +%FT%TZ)" 'select(.status != "success" and .time > $since)' "$STATS_LOG"

# Average send duration per dataset:
jq -s 'group_by(.dataset) | map({dataset: .[0].dataset, avg_s: (map(.duration_s) | add / length)})' "$STATS_LOG"
```

## snapsend.sh (wysyłka)

Źródło jest zawsze lokalne; cel może być lokalny lub zdalny (`[user@]host:dataset`). Tworzy nową
migawkę (albo użyje najnowszej istniejącej przy `-e`), znajduje najlepszą bazę przyrostu (dopasowanie
po nazwie, potem po GUID, potem po bookmarku, na końcu pełne wysłanie) i przesyła ją. Jest też
silnikiem odzysku na miejsce i lokalnych zadań samych migawek.

**Wysyłka zdalna to tryb CLI dla istniejących flot.** GUI tworzy relacje pobierania, lustra, kopii
lokalnej i samych migawek, a okna dla wysyłki nie ma. Żeby założyć ją ręcznie: uruchom
`deploy.sh --pair --role=push --peer=KOLEKTOR` na źródle i `deploy.sh --join=…` na kolektorze, potem
dodaj do configu źródła sekcję `[dataset:]` z `dst = konto@KOLEKTOR:cel` i
`flags = -K <klucz parowania> -k <przypięty known_hosts>` i zainstaluj ją przez
`gen-cron.sh --install`. Żeby przenieść taką relację na nowy adres kolektora, zmień `dst` i dodaj
`-O HostKeyAlias=<stary adres>` do `flags`, po czym zainstaluj ponownie: klucz hosta został
przypięty pod starym adresem i bez aliasu ssh odrzuci nowy. Żeby rozebrać, uruchom
`deploy.sh --unpair` na źródle, a potem trzy komendy, które wypisze, na kolektorze (`zfs unallow`,
`userdel -r`, `rm` manifestu).

```
Usage: snapsend.sh [options] DATASETS [REMOTE]
```

| Flaga | Znaczenie |
|---|---|
| `-m <KOMUNIKAT>` | Prefiks nazwy nowej migawki. Pominięcie jest dozwolone, ale ostrzegane, patrz niżej |
| `-e` | Użyj istniejącej najnowszej migawki zamiast tworzyć nową |
| `-E <PREFIKS>` | Z `-e`: nigdy nie przyjmuj za najnowszą/bazę migawki, której nazwa zaczyna się od PREFIKS, nawet gdy jest nowsza (wygrywa najnowsza niewykluczona). Powtarzalne. Do biernego podbierania migawek obcego systemu |
| `-t` | Drugi argument to DOKŁADNY dataset do zapisu, a nie baza, pod którą dopisuje się nazwę źródła. Używane przez odzysk, gdzie kopia musi wrócić na swoją oryginalną ścieżkę. Odmowa przy kilku datasetach, bez bazy i z `-R` |
| `-z` / `-Z` | Kompresuj strumień zstd (`-Z` to synonim `-z`). Domyślnie włączone wobec zdalnego celu |
| `-g` | Kompresuj pigz zamiast tego (wyjście awaryjne, gdy zstd jest niedostępny) |
| `-N` | Bez kompresji: rezygnacja z domyślnej wobec zdalnego. Przeczy `-z`/`-Z`/`-g` |
| `-l <POZIOM>` | Poziom kompresji (domyślnie 3 dla zstd, 6 dla pigz; skale się różnią) |
| `-v <POZIOM>` | Gadatliwość od 0 (tylko błędy, domyślnie) do 4 (debug) |
| `-r` | Rekurencyjnie: dołącz datasety potomne w jednym atomowym strumieniu `zfs send -R` dla całego poddrzewa |
| `-R` | Płasko-rekurencyjnie, zgodnie z syncoid/sanoid: najpierw rozwiń do każdego potomka (`zfs list -r`, bez limitu głębokości), potem wyślij każdy jako osobne, niezależne zadanie. Wyklucza się z `-r`; zobacz [Tryby rekurencji](#tryby-rekurencji) |
| `-X <REGEX>` | **Tylko `-R`.** Odrzuć każdy rozwinięty dataset, którego pełna nazwa pasuje do REGEX (rozszerzony regex, bez kotwic). Powtarzalne. Zobacz [Filtrowanie rozwinięcia](#filtrowanie-rozwinięcia) |
| `-S` | **Tylko `-R`.** Skip-parent: wyślij potomków, ale nie sam wskazany dataset |
| `-n` | Próba na sucho: zgłoś konflikty, nic nie wysyłaj |
| `-H` | Wysyłka pełnej historii, jeśli nie ma wspólnej bazy (zamiast zwykłego pełnego wysłania) |
| `-u` | Przyjmowane i ignorowane: niemontowanie jest domyślne |
| `-U` | Zamontuj cel po odbiorze; zobacz [Montowanie celu](#montowanie-celu) |
| `-f` | Wymuś pełne wysłanie: zniszcz dane celu, zasiej od zera |
| `-w` | Wysyłka surowa (`zfs send -w`): przesyła zaszyfrowane źródło jako szyfrogram, żaden klucz nie jest potrzebny po żadnej stronie; praktycznie bez efektu na danych niezaszyfrowanych |
| `-p <PORT>` | Port SSH (domyślnie 22) |
| `-c <SPEC_SZYFRU>` | Szyfr(y) SSH do zażądania (`ssh -c`), np. `aes128-gcm@openssh.com` dla łącza ograniczonego przez CPU. Domyślnie: pozwól ssh/sshd wynegocjować. Bez efektu przy uruchomieniu lokalnym |
| `-k <PLIK>` | Weryfikuj klucz zdalnego hosta względem tego pliku known_hosts (domyślnie: zaufanie przy pierwszym użyciu, potem odmowa, jeśli klucz się zmieni) |
| `-K <PLIK>` | Prywatny klucz SSH (`ssh -i`, plus `-o IdentitiesOnly=yes`, żeby agent z innymi kluczami nie doprowadził do zablokowania konta przez limit max-auth-tries). Nie `-i`, które tu oznacza pomijanie pośrednich |
| `-O <OPCJA_SSH>` | Dodatkowe `ssh -o NAZWA=WARTOŚĆ`, dosłownie, np. `-O "ProxyJump=bastion"`. Powtarzalne. Umieszczane **na początku** linii poleceń ssh; OpenSSH zachowuje pierwszą wartość, jaką zobaczy dla klucza, więc jawne `-O` może nadpisać `-p`/`-k`/`-c`/`-K` albo wyłączyć multipleksowanie przez `-O ControlMaster=no` |
| `-b <TEMPO>` | Ogranicz tempo transferu; zobacz [Ograniczanie przepustowości](#ograniczanie-przepustowości) |
| `-A` | Autodostrajanie łącza; zobacz [Autodostrajanie łącza](#autodostrajanie-łącza) |
| `-q <TRYB>` | Najpierw zamroź gościa Proxmoxa będącego właścicielem; zobacz [Zamrażanie](#zamrażanie-gości-proxmoxa) |
| `-j <TAG>` | Identyfikator zadania; zobacz [Identyfikatory zadań](#identyfikatory-zadań) |
| `-i` | Pomiń migawki pośrednie przy przyroście (`zfs send -i` zamiast `-I`); zobacz [Pomijanie migawek pośrednich](#pomijanie-migawek-pośrednich) |
| `-T <N>` | Automatycznie przełącz na `-i`, gdy od wspólnej bazy upłynęło więcej niż N własnych interwałów migawek datasetu; zobacz [Automatyczny próg nadrabiania](#automatyczny-próg-nadrabiania) |
| `-o "<FLAGI>"` | Surowe flagi dopisywane dosłownie do `zfs send` (np. `-o "-L -e"`). Bez walidacji. Pomijane na ścieżce wznowienia, gdzie token już ustala format strumienia |
| `-x <WŁAŚCIWOŚĆ>` | Wyklucz WŁAŚCIWOŚĆ przy odbiorze (`zfs recv -x`). Powtarzalne; stosowane przy normalnym i wznowionym odbiorze |
| `-F` | Uzgodnij przed wysłaniem (rekurencyjnie przy `-r`; bez efektu przy `-R`): jeśli **potomny** dataset ma migawkę o nazwie takiej jak baza przyrostu pod *innym GUID-em* (prawdziwa kolizja, nie tylko starsza osierocona historia), podnieś ten przebieg do pełnego ponownego wysłania całego poddrzewa, tak jak robi `-f`. Celowo węższe niż raport `-n`: migawka tylko na celu, która nie jest kolizją nazwy (archiwum trzymające dłuższą historię niż źródło), jest normalna i zostaje w spokoju |
| `-L <ETYKIETA>` | Relacja (klient `zfs-backup.sh`), do której należy ten przebieg. Jeśli jest spauzowana (`pause-client`), przebieg kończy się kodem 0 z „SKIPPED: relationship ETYKIETA is paused” przed jakąkolwiek blokadą, migawką czy pracą ssh i loguje `skipped_paused`. Wpisywane w wygenerowane linie przez `pair_label`. Przebieg bez `-L` nie jest bramkowany: pauza to orkiestracja, nie granica bezpieczeństwa |
| `-V` | Wypisz wersję i zakończ |

**Uruchomienie bez `-m` jest dozwolone, ale ostrzegane** (gadatliwość 0, więc widać to w domyślnym
przebiegu crona). Nazwa migawki to `${MESSAGE}$(date ...)`, więc pusty `MESSAGE` daje sam znacznik
czasu (`2026-07-26_22-51-22` zamiast `automated_hourly_2026-07-26_22-51-22`), a `delsnaps.sh`
dopasowuje po dosłownym **prefiksie**, więc żaden prawdziwy wzorzec retencji nigdy do niej nie
pasuje. Nic takiej migawki nie usuwa, chyba że reguła celuje w nią wprost (zobacz drabina `-G`).
Każda linia wygenerowana przez `gen-cron.sh` jest przed tym bezpieczna, bo `prefix` jest tam
polem wymaganym, więc ostrzeżenie odpala tylko przy ręcznym wywołaniu. Ostrzeżenie **nie** odpala
przy `-e`: nic nowego nie powstaje, a najnowsza istniejąca migawka, nawet taka, której to narzędzie
nie zrobiło, jest podbierana bez zmian. To celowa elastyczność.

```bash
snapsend.sh -v1 pool/data backuppool/data_backup
snapsend.sh -r pool/data user@backuphost:tank/backups/data
```

## snapget.sh (pobranie)

Lustrzane odbicie `snapsend.sh`: cel jest zawsze lokalny, źródło może być lokalne lub zdalne.
Przyjmuje każdą flagę `snapsend.sh` (`-m -e -E -t -z -Z -g -N -l -v -r -R -X -S -n -H -i -T -u -U -f
-w -p -c -k -K -O -b -A -j -o -x -F -L -q -V`) z zamienionymi miejscami źródła i celu: `-o`
dotyczy zdalnego `zfs send`, `-x` lokalnego odbioru, `-F` zawsze niszczy lokalnie, bo cel jest
zawsze lokalny, a listowanie potomków przy `-R` biegnie przez ssh, gdy źródło jest zdalne. `-q`
działa tak, jak opisano w [Zamrażaniu](#zamrażanie-gości-proxmoxa): gość żyje na źródle, więc
zamrożenie odbywa się tam. Trzy flagi istnieją tylko tutaj:

| Flaga | Znaczenie |
|---|---|
| `-M` | Lustro (relacje sync): po udanym pobraniu zniszcz na celu każdą migawkę, której źródło już nie ma, a która jest STARSZA niż wspólna baza, żeby cel trzymał to, co źródło. Nigdy bazy ani niczego nowszego, nigdy zarezerwowanej rodziny Proxmoxa, i nic w ogóle, gdy lista źródła nie daje się odczytać albo wraca pusta. Rozstrzygane per dataset, więc przy `-R` każde rozwinięte dziecko lustruje swoje własne źródło. Nie z `-r` |
| `-s` | Tylko migawki, bez transferu: robi migawkę (migawki) źródła tam, gdzie źródło żyje (przez ssh dla `[user@]host:dataset`, lokalnie dla samego datasetu) i na tym kończy: nic nie jest wysyłane, odbierane, trzymane holdem, bookmarkowane, lustrowane ani tworzone tutaj. Dla datasetów, które inny mechanizm już kopiuje (`pvesr` w klastrze Proxmoxa) i które potrzebują tylko własnej rodziny migawek tej relacji. Przyjmuje dokładnie jeden argument pozycyjny (listę źródeł); argument celu i każda flaga, która tylko kształtuje transfer, są odrzucane przed jakimkolwiek ssh czy migawką (`-e -t -M -f -F` oraz `-z -Z -g -N -l -A -b -H -i -T -w -o -x -u -U -E`). `-m -j -v -n -r -R -X -S -q -Q -L -p -k -K -O -c` zostają. Nie potrzebuje ani mbuffera, ani kompresora. `-n` wypisuje jedną linię `PLAN=SNAPSHOT-ONLY src=<dataset>` na każdy wybrany dataset. Status w statystykach to `snapshot_only` lub `snapshot_only_failed`, nigdy `success` |
| `-Q <SEKUNDY>` | Jak długo zdalny deadman czeka, zanim odmrozi bezwarunkowo (domyślnie 120, minimum 10). Ma sens tylko z `-q` |

```bash
snapget.sh -v1 pool/data backuppool/data_backup
snapget.sh -r user@sourcehost:pool/data tank/backups
```

Przy pobraniu strona zdalna jest CZYTANA i podawana dosłownie; strona lokalna dostaje opcjonalną
bazę.

### Tryby rekurencji

Oba przechodzą całe drzewo datasetów bez limitu głębokości. Różnica dotyczy jednostki pracy, a nie
głębokości:

- **`-r`**: jeden atomowy strumień `zfs send -R` niesie całe poddrzewo, a jeden `zfs recv` ląduje
  je w całości naraz. Wszystko albo nic, a pojedyncza kolizja GUID gdziekolwiek w drzewie (zobacz
  `-F`) wymusza pełne ponowne wysłanie wszystkiego, bo `zfs send -R -I` rozstrzyga pełne-kontra-
  przyrostowe per dziecko z historii *źródła*, a nie z tego, co przetrwało na celu. Silniki nie
  trzymają bookmarka przy `-r`, więc prune źródła, które postarza ostatnią wspólną migawkę, kończy
  relację aż do destrukcyjnej ponownej pełnej kopii.
- **`-R`**: zgodne z syncoid/sanoid. Najpierw rozwija drzewo do płaskiej listy, potem każdy dataset
  przechodzi niezależnie zwykłą ścieżką pojedynczego datasetu. Dziecko, które zawodzi lub koliduje,
  dotyka tylko siebie, a każde trzyma własny bookmark.

Używaj `-r` dla własnych dysków pojedynczego gościa, gdzie wszystko-albo-nic jest tym, czego
chcesz (zobacz [Zamrażanie](#zamrażanie-gości-proxmoxa)). Używaj `-R` dla całego poddrzewa
niezależnych datasetów, gdzie problem jednego datasetu nie powinien blokować reszty. W configach
to pole `recursive =` (`no`, `flat` = `-R`, `atomic` = `-r`); `-r`/`-R` w dowolnym polu `flags` to
twardy błąd.

**Zapomnienie obu jest wychwytywane.** Wskazanie datasetu, który trzyma tylko dzieci (na przykład
`rpool/data` na hoście Proxmoxa), bez `-r` ani `-R` wysyła rodzica i nic więcej, i *zgłasza
sukces*: rodzic jest prawdziwym datasetem, więc transfer się udaje, log statystyk zapisuje sukces,
a `check-snap-age.sh` widzi świeżą migawkę. Dlatego oba silniki sprawdzają bezpośrednie dzieci,
ilekroć żadna flaga rekurencji nie jest ustawiona, i ostrzegają przy gadatliwości 0 (więc także w
domyślnym przebiegu crona):

```
WARNING: rpool/data has 1 child dataset(s) but neither -r nor -R was given -- only rpool/data
itself is being sent, its children are NOT. Add -R (independent per-dataset jobs) or -r (one
atomic recursive stream) if you meant to include them.
```

To ostrzeżenie, a nie błąd, bo replikowanie samego rodzica jest uprawnione. Odpala także przy
`-n`, bo podgląd to najlepszy moment, żeby się dowiedzieć, że zadanie celuje w pusty kontener.

### Filtrowanie rozwinięcia

Przy `-r` poddrzewo to jeden atomowy strumień, w którym nie ma gdzie filtrować, więc `-X` i `-S`
są **odrzucane bez `-R`**, a nie ignorowane.

```bash
# Everything under rpool/data except the swap volumes:
snapsend.sh -R -X 'swap' -m daily_ rpool/data user@backup:hdd/backups/src-a

# Only the children; rpool/data itself is an empty container:
snapsend.sh -R -S -m daily_ rpool/data user@backup:hdd/backups/src-a
```

- **`-X <REGEX>`** (`--exclude` z syncoid): rozszerzony regex (`grep -E`), dopasowywany **bez
  kotwic** do pełnej nazwy datasetu. Powtarzalny; dataset odpada, jeśli pasuje którykolwiek wzorzec.
  W `snapget.sh` testowana nazwa to pełna ścieżka **po stronie źródła**, więc jeden regex czyta
  się tak samo w obu kierunkach. Błędny regex kończy się błędem przed zrobieniem jakiejkolwiek
  migawki.
- **`-S`** (`--skip-parent` z syncoid): wyślij potomków każdego wskazanego datasetu, nigdy sam
  dataset.

**Kotwiczenie ma znaczenie.** Pełna nazwa dziecka zawiera nazwę rodzica, więc wzorzec bez kotwic,
który pasuje do rodzica, pasuje też do wszystkiego pod nim:

| Wzorzec | `rpool/swap` | `rpool/swap/inner` |
|---|---|---|
| `-X swap` | wykluczony | **też wykluczony** |
| `-X 'swap$'` | wykluczony | nadal wysyłany |

Oba są uprawnione; zdecyduj, które miałeś na myśli. Wykluczenie datasetu samo z siebie nie wyklucza
jego potomków, a `zfs create -p` nadal tworzy pominięty poziom na celu jako pusty dataset, żeby
ocalałe dziecko miało gdzie wylądować.

**Odfiltrowanie wszystkiego to błąd** (kod 1, nic nie dostało migawki). Literówka w regexie albo
`-S` na datasecie bez dzieci kończyłyby się w przeciwnym razie kodem 0 przy niczym niewysłanym, co
w cronie nie różni się od zdrowego przebiegu.

## delsnaps.sh (retencja i prune)

Dwa wzajemnie wykluczające się tryby, wybierane wielkością litery flagi:

- **Wg wieku** (małe litery `-y -m -w -d -h`): usuń wszystko starsze niż zsumowany próg.
- **Wg liczby** (wielkie litery `-Y -M -W -D -H`): zostaw tylko N najnowszych pasujących migawek,
  sumowanych po slotach.

```
delsnaps.sh [options] <comma-separated datasets> <pattern> <age or count flags>

Options:
-R                 Recurse into every descendant dataset (each keeps its OWN retention)
-n                 Dry-run: print what would be deleted/kept, destroy nothing
-v, --verbose      Verbose tracing (also DEBUG=1)
-F                 Clear-cut: zfs destroy -R instead of a plain destroy. Cascades to
                   same-named descendant snapshots AND dependent clones. Opt-in; dangerous.
-B                 Bookmark mode: prune orphaned snapsend/snapget bookmarks instead of
                   snapshots (age-based only)
-G                 GFS cascading ladder instead of a flat count sum (count-based
                   -H/-D/-W/-M/-Y only)
-p <PORT>          SSH port for remote datasets
-k <FILE>          Known-hosts file for remote datasets
-c <CIPHER_SPEC>   SSH cipher(s) to request; same as snapsend.sh/snapget.sh -c
-K <FILE>          SSH private key (ssh -i + IdentitiesOnly=yes); same as -K there
-O <SSH_OPTION>    Extra "ssh -o NAME=VALUE", repeatable, placed first; same as -O there
-P <prefix>:<keep> How many of the NEWEST reserved snapshots to protect, per dataset
                   (default: __replicate_/__migration__/vzdump all protected)
-L <LABEL>         The relationship this run belongs to. While it is paused the run
                   exits 0 without destroying anything ("SKIPPED: relationship ... is paused")
-V, --version      Print version and exit
```

Zwykły destroy odmawia usunięcia migawki z zależnymi klonami (na przykład żywy dysk linked-clone
Proxmoxa); jest to zgłaszane i pomijane, a nie po cichu niszczone. `-F` włącza kaskadę, gdy
naprawdę jej chcesz. Datasety mogą być zdalne (`[user@]host:ścieżka`; zdalny tylko wtedy, gdy jest
`:` bez `/` przed nim), a wpisy lokalne i zdalne można mieszać w jednej liście rozdzielonej
przecinkami.

**Nieudane zdalne listowanie to błąd, a nie pusty wynik.** Każdy błąd ssh lub zfs przy listowaniu
migawek lub bookmarków zdalnego datasetu (zły port, odwołany klucz, fałszywy szyfr `-c`, host
wyłączony) kończy się kodem 1 i alarmuje jak każde inne zepsute zadanie, zamiast logować „No
snapshots found” i kończyć się kodem 0, co pozwoliłoby zdalnemu zadaniu retencji psuć się po cichu
w nieskończoność.

```bash
# Age-based, recursive, two datasets:
./delsnaps.sh -R "tank/data1,tank/data2" "backup-" -y1 -m6

# Count-based, single dataset, keep the 12 most recent monthlies:
./delsnaps.sh "tank/data4" "monthly-" -M12

# Preview only:
./delsnaps.sh -n "tank/data4" "monthly-" -M12

# Remote, custom SSH port:
./delsnaps.sh -p2222 "backup@src-a:tank/data" "monthly-" -M12
```

**Pusty wzorzec albo brak jakichkolwiek flag wieku/liczby jest celowo nieograniczony.** Dopasowanie
jest po dosłownym prefiksie, więc pusty wzorzec pasuje do *każdej* migawki w zakresie. Bez żadnej
flagi wieku ani liczby skrypt przyjmuje tryb wieku z progiem = teraz, co usuwa wszystko, co już
tam jest. Żadne z tych nie zostanie zwalidowane na zero: to narzędzie admina, a operator, który
wyraźnie prosi o prune każdej migawki w zakresie, dostaje dokładnie to. Dwie rzeczy przetrwają
każde takie wywołanie: `is_protected_snapshot()` (własne migawki Proxmoxa `__replicate_`,
`__migration__` i `vzdump`, chyba że poluzowano je przez `-P`) oraz hold `zfssnapall_inflight`
(`zfs destroy` odmawia, a migawka jest zgłaszana, a nie po cichu pomijana). Połączenie pustego
wzorca z `-F` czyni zarówno zakres dopasowania, jak i metodę niszczenia tak przyzwalającymi, jak
się da. Strzeżone jest to, żeby generator configu nie produkował tego przypadkiem, a nie na
życzenie; zobacz [Co wymusza generator](#co-egzekwuje-generator).

### Ochrona zarezerwowanych prefiksów

Migawki o nazwach `__replicate_*`, `__migration__*` i `vzdump*` należą do samego Proxmoxa, a
wykonanie prune jednej z nich spod `pvesr` nieodwracalnie psuje łańcuch replikacji, więc domyślnie
chronione są *wszystkie*. Ale ochrona absolutna czyni je **nieśmiertelnymi**, co jest błędne w
jednym miejscu: na **celu backupu**, który odebrał strumień replikacji. `-r`/`-H` niosą każdą
migawkę ze źródła, nie tylko te, które zrobiło to narzędzie, więc te zarezerwowane migawki lądują
na celu, gdzie nic ich nigdy nie czyści, choć wartość dla przyszłego przyrostu ma tylko najnowsza.
`-P <prefiks>:<ile>` (albo `[excluded:<prefiks>]` w configu) ustawia, ile **najnowszych** zachować,
*per dataset*:

```bash
./delsnaps.sh -P "__replicate_:1" tank/backups "__replicate_" -H0   # keep the newest, prune the rest
```

Działa **per prefiks** (poluzowanie `__replicate_` zostawia `__migration__` i `vzdump` absolutnie
chronione), **per dataset** (każdy niesie własny łańcuch replikacji) i tylko **rozluźnia
zabezpieczenie, nigdy nie poszerza dopasowania**: starsza zarezerwowana migawka nadal musi pasować
do wzorca przebiegu, żeby została usunięta, więc rutynowe zadanie `"automated_hourly_"` nie może
jej tknąć nawet przy całkowicie wyłączonej ochronie (`:0`).

### Prune bookmarków

`-B` sprząta polisę ubezpieczeniową jednego bookmarka na cel, którą zostawiają
`snapsend.sh`/`snapget.sh` (zobacz [Przyrostowy fallback oparty na
bookmarkach](#przyrostowy-fallback-oparty-na-bookmarkach)): gdy cel zostaje wycofany, jego
bookmark nigdy więcej nie jest ruszany i żyłby wiecznie. `-B` usuwa każdy bookmark, który nie był
odświeżony w podanym wieku. Wybierz próg bezpiecznie dłuższy niż twój najdłuższy prawdziwy cykl
backupu, bo inaczej wciąż ważny bookmark spauzowanego lub offline zadania zostanie usunięty za
wcześnie.

```bash
# Prune snapsend/snapget bookmarks untouched for 30+ days, across a whole subtree:
./delsnaps.sh -B -R "tank/data" "tgt-" -d30
```

### Drabina kaskadowa GFS

`-G` jest dla zakresu bez konwencji nazewniczej, po której dałoby się robić prune: migawek
zrobionych bez `-m` (same znaczniki czasu, zobacz [notkę o `-m`](#snapsendsh-wysyłka)) albo
każdego zakresu, w którym wszystkie migawki wyglądają dla dopasowania prefiksu tak samo. Zwykłe
flagi liczby **sumują się**: `-H24 -D7` zostawia 31 najnowszych migawek niezależnie od tego, jak
rozłożono je w czasie. `-G` nadaje tym samym pięciu literom sens GFS (Grandfather-Father-Son):
każda staje się własnym, nienakładającym się szczeblem kaskadowej wieży, przechodzonej w stałej
kolejności, a zasięg każdego szczebla zaczyna się tam, gdzie kończy się poprzedni:

| Flaga | Szczebel | Szerokość kubełka | Zachowany ocalały |
|---|---|---|---|
| `-H<N>` | Godzinowy | 1 godzina | najnowsza migawka w tej godzinie |
| `-D<N>` | Dzienny | 1 doba, zaraz po końcu zasięgu godzinowego | najnowsza migawka w tej dobie |
| `-W<N>` | Tygodniowy | 1 tydzień, zaraz po końcu dziennego | najnowsza migawka w tym tygodniu |
| `-M<N>` | Miesięczny | 30 dni, zaraz po końcu tygodniowego | najnowsza migawka w tym miesiącu |
| `-Y<N>` | Roczny | 365 dni, zaraz po końcu miesięcznego | najnowsza migawka w tym roku |

Pominięta litera po prostu nie ma szczebla (`-H24 -D7` samo to prawidłowa drabina dwuszczeblowa).
Pusty kubełek (dziura w kadencji samego źródła) nie ma ocalałego i nic nie jest zmyślane, by go
wypełnić. Wszystko starsze niż najdalszy zażądany szczebel i wszystko wewnątrz szczebla, co nie
jest ocalałym danego kubełka, jest usuwane, z zachowaniem tych samych ochron zarezerwowanych
prefiksów i holdów w locie co w każdym innym trybie. Przy `-R` każdy potomek dostaje własną
drabinę, ale wszystkie dzielą jedno „teraz”, obliczone raz na początku przebiegu.

```bash
# Thousands of unpruned, unpatterned hourly snapshots. Preview first, always,
# the first time -G touches a real dataset:
./delsnaps.sh -n -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3

# Output looks right? Drop -n and it actually prunes:
./delsnaps.sh -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3
```

`-G` działa także z prawdziwym wzorcem: drabina układa w kubełki to, co najpierw pasuje do wzorca.
Jest odrzucane w połączeniu z małymi flagami wieku, z `-B` oraz gdy podano je bez żadnego
`-H`/`-D`/`-W`/`-M`/`-Y`.

## check-snap-age.sh (strażnik świeżości)

Tylko do odczytu, w stylu Nagiosa: dla każdego datasetu znajduje najnowszą migawkę, której nazwa
(po `@`) zaczyna się od podanego wzorca, i porównuje jej wiek z progami warn i crit. Niczego nie
tworzy, nie wysyła ani nie niszczy.

```
Usage: check-snap-age.sh [-R] [-v] [-L LABEL] [-x PREFIX]... [-p PORT] [-k KNOWN_HOSTS] [-c CIPHER]
                         [-K KEY] [-O OPTION]... <comma-separated datasets> <pattern> <warn> <crit>
```

| Flaga | Znaczenie |
|---|---|
| `-R`, `--recursive` | Sprawdź też każdy dataset potomny, niezależnie, względem tego samego wzorca i progów |
| `-v`, `--verbose` | Wypisz linię stanu dla każdego datasetu, nie tylko dla tych, które przekraczają próg |
| `-L <ETYKIETA>` | Relacja, do której należą datasety. Gdy jest spauzowana, sprawdzenie kończy się OK z sformułowaniem wskazującym pauzę: nieświeżość jest oczekiwanym stanem celowo zatrzymanego backupu |
| `-x <PREFIKS>` | Powtarzalne. Migawki, których nazwa zaczyna się od PREFIKS, są dla strażnika niewidoczne: ani nie spełniają świeżości, ani jej nie podnoszą. Dla relacji biernych, które obserwują „cokolwiek obcy system stempluje” |
| `-p -k -c -K -O` | Port ssh, przypięty plik known_hosts (ścisła kontrola klucza hosta; bez `-k`, accept-new), szyfr, plik tożsamości i dodatkowe opcje `-o`. Te same pięć co w `delsnaps.sh`, używane dla wpisów zdalnych |
| `-V`, `--version` | Wypisz wersję i zakończ |

Wpis datasetu może mieć postać `[user@]host:dataset` i jest wtedy czytany przez ssh na tym hoście
(tylko do odczytu: wyłącznie `zfs list` i `zfs get`; ssh jest nieinteraktywne i ograniczone
czasowo). Strażnik działa na hoście, który jest właścicielem *harmonogramu*: dla relacji migawek
zdalnych jest to kolektor, którego cron robi migawki na źródle, więc źródło to miejsce, gdzie leżą
migawki, a kolektor to miejsce, gdzie się je sprawdza. Progi mają postać `<N><jednostka>` z
jednostką `m`/`h`/`d` (na przykład `90m`, `3h`, `9d`); crit musi być co najmniej równe warn.

**Kody wyjścia** (najgorszy spośród wszystkich sprawdzonych datasetów): `0` OK, `1` WARNING, `2`
CRITICAL, `3` UNKNOWN. UNKNOWN znaczy, że samo sprawdzenie nie mogło odpowiedzieć (złe argumenty,
brak `zfs`, nieistniejący dataset, nieudane ssh lub listowanie) i jest celowo odrębne od „odpowiedź
jest zła”, żeby zepsuty strażnik nie czytał się jako „wszystko w porządku”. Każdy odczyt jest
sprawdzany: nieudana lista migawek albo nieudane przejście `-R` to UNKNOWN, nigdy pusty sukces.
CRITICAL przeważa nad UNKNOWN w końcowym kodzie wyjścia, a każde ustalenie trafia też na stderr.
Dataset **bez** pasującej migawki jest oceniany po wieku *samego datasetu* tą samą drabiną
warn/crit, więc gość utworzony po ostatnim zaplanowanym przebiegu nie jest zgłaszany jako nieświeży
backup czegoś, co nie miało szansy go mieć; dataset, którego czasu utworzenia nie da się odczytać,
to UNKNOWN.

```bash
./check-snap-age.sh "rpool/data/vm-106-disk-0" "automated_hourly" 90m 3h
./check-snap-age.sh -R "hdd/backups/src-a" "automated_daily" 30h 48h
./check-snap-age.sh -p 2222 -K /etc/zfs-backup-id_ed25519 "backup@src-a:tank/data" "automated_hourly" 90m 3h
```

## gen-cron.sh (generator crona sterowany configiem)

Czyta jeden plik config w stylu INI i wypisuje blok crontaba, który dla danego hosta uruchamia
`snapsend.sh`/`snapget.sh`/`delsnaps.sh`/`check-snap-age.sh` — bez ręcznie pisanych linii crona.
`--install` jest idempotentne: zastępuje własny, wcześniej wygenerowany blok, zamiast dopisywać
nowy. Na hoście zarządzanym `zfs-backup.sh` zapisuje config i wywołuje generator za ciebie
(`zfs-backup.sh show-config NAME` wypisuje config, w którym jest dana relacja, a
`zfs-backup.sh edit-config` edytuje go z walidacją); bezpośrednie wywołanie `gen-cron.sh` jest drogą
dla ręcznie pisanego configu. Gotowe configi dla ekspertów znajdziesz w
[PRZYKLADY-CONFIGU.md](PRZYKLADY-CONFIGU.md).

### Opcje

```
Usage: gen-cron.sh [-c CONFIG] [--install] [--uninstall] [--reconcile] [--migrate-recursion] [-V] [-h]
```

| Opcja | Znaczenie |
|---|---|
| `-c <FILE>` | Plik config (domyślnie `jobs.<hostname -s>.conf` obok skryptu) |
| `--install` | Zainstaluj lub zastąp zarządzany blok w crontabie tego użytkownika. Bez tej opcji blok jest wypisywany na stdout do przejrzenia |
| `--uninstall` | Usuń zarządzany blok i zakończ. Nie wymaga `-c`: zwykle powodem jest to, że config zniknął albo jest błędny. Usuwa tylko harmonogram, nigdy config ani datasety |
| `--reconcile` | Tylko do odczytu: porównuje to, co config zabezpiecza, z tym, co istnieje na tym hoście, i kończy się kodem różnym od zera, jeśli jakiś dataset nie ma zadania SEND. Dataset z samą regułą prune jest przycinany, a nie zabezpieczany. Odpowiada na awarię, w której gość utworzony po napisaniu configu działał bez żadnej migawki, bo nikt nie porównał jednego z drugim. Wymaga `zfs` na tym hoście |
| `--migrate-recursion` | Przepisuje config, w którym rekursja była zapisana jako `-r`/`-R` wewnątrz dowolnego `flags`, na własne `recursive =` sekcji, i pokazuje crontab przed i po, żeby wynik można było porównać przed instalacją. Jednorazowa migracja |
| `-V`, `--version` | Wypisz wersję i zakończ |
| `-h` | Wypisz pomoc |

Każde pole harmonogramu (`send_schedule`, `prune_schedule`, `monitor_schedule` oraz
`schedule` w `[prune-bookmarks:]`) musi mieć dokładnie pięć pól crontaba, każde w dozwolonym
zakresie; skróty w stylu `@daily` nie są przyjmowane. **Nieznane nazwy pól są odrzucane** w każdym
typie sekcji, więc literówka nie wygeneruje się bez błędu i nie zrobi nic.

### Bloki relacji: co zapisuje narzędzie

Relacja to jeden blok `[relation:NAME]`, który niesie całą jej politykę: szczeble, ich retencję
i harmonogramy obu stron. Sekcje `[dataset:]` i `[prune:]` tej relacji wskazują na niego przez
`relation = NAME` i podają, po której stronie są, przez `side`. Tak zapisują to `zfs-backup.sh`
i GUI; te bloki zwykle czytasz, a nie piszesz. Config kolektora dla jednego źródła z jednym
datasetem (przykład):

```ini
[relation:src-a]
	tiers = hourly, daily
	hourly.target_send_schedule = 1 * * * *     # values from the template;
	hourly.prune_schedule = 21 * * * *          # the minutes of each dataset below
	hourly.target_prefix = automated_hourly_    # are spread from these
	hourly.pattern = automated_hourly
	hourly.retain = -H24
	hourly.monitor = 90m 150m
	daily.target_send_schedule = 11 1 * * *
	daily.target_prefix = automated_daily_
	daily.target_retain = -D30
	daily.source_retain = -D5

[dataset:hdd/backups/src-a/hdd/data]           # the copy, on the collector
	relation     = src-a
	side         = target
	send_schedule_hourly = 13 * * * *           # this dataset's own minute
	send_schedule_daily = 23 1 * * *
	prune_schedule_hourly = 33 * * * *          # pruning of the COPY: send minute + 20
	prune_schedule_daily = 43 1 * * *
	# src, pair_label and flags are written by the tool

[prune:zfsbackup-collector@10.0.0.9:hdd/data]  # pruning of the SOURCE, over ssh
	relation     = src-a
	side         = source
	prune_schedule_hourly = 53 * * * *          # pruning of the SOURCE: send minute + 40
	prune_schedule_daily = 3 2 * * *
```

Druga i trzecia sekcja są ważne: backup tworzy migawki także na źródle, a bez prune z `side = source`
pula źródła rośnie bez końca.

Zasady:

- Klucze bloku to `tiers` (lista rozdzielona przecinkami, od najdrobniejszego), `gfs` (opcjonalny,
  każdy szczebel zasila jedną drabinę GFS), ustawienia silnika `history compression cipher autotune
  raw` (żyją tylko w bloku; ustawienie któregoś dodatkowo w sekcji jest odrzucane) oraz klucze
  per szczebel `<tier>.<field>`.
- `<field>` to dowolne pole szablonu (`send_schedule prune_schedule prefix pattern keep retain
  quiesce notify_word tier_label monitor_warn monitor_crit monitor_schedule gfs ...`) oraz
  `monitor` (= `monitor_warn monitor_crit`, dwa czasy: najpierw warn, potem crit).
  `<tier>.target_<field>` dotyczy tylko strony celu, a `<tier>.source_<field>` tylko strony
  źródła; zapis dla konkretnej strony wygrywa z zapisem ogólnym. `<tier>.target = no` lub
  `<tier>.source = no` wyłącza szczebel po tej stronie.
- `side` jest zawsze podawane, nigdy zgadywane: `side = target` dla kopii, `side = source` dla
  oryginałów. (Retencja źródła relacji lokalnej to `[prune:<ścieżka źródła>]` bez `@` i nadal jest
  to źródło.)
- Sekcja bierze szczeble z jednego miejsca: `relation` i `use_template` w tej samej sekcji jest
  odrzucane, blok, na który nie wskazuje żadna sekcja, jest odrzucany, a sekcja, której `pair_label`
  nazywa inną relację, jest odrzucana. Szczebel zdefiniowany w bloku nie może jednocześnie istnieć
  jako sekcja `[template:]`.
- Każdy dataset i każda relacja dostają na kolektorze własną wolną minutę (wybraną raz, przy
  tworzeniu, z hasha nazwy, a potem jako pierwsza minuta, której host jeszcze nie używa); prune celu
  idzie o minutę wysyłki + 20, a prune źródła o minutę wysyłki + 40. `send_schedule_<tier>` i
  `prune_schedule_<tier>` ustawione w sekcji nadpisują wartości bloku.
- `zfs-backup.sh show-tiers NAME`, `set-tiers` i `edit-relation` czytają i zmieniają te bloki.

### Typy sekcji

Nagłówek ma zawsze postać `[type:name]`, dzieloną na pierwszym `:`, z wyjątkiem `[defaults]`.

| Sekcja | Przeznaczenie |
|---|---|
| `[defaults]` | `host_label` (używane w tekście powiadomień), opcjonalny domyślny `dst`, pięć ścieżek, które trafiają do każdej wygenerowanej linii (`repo_dir`, `notify_script`, `warn_script`, `digest_script` (`none` nie emituje linii digestu), `cron_log`; wszystkie bezwzględne, każdą nadpisuje zmienna środowiskowa pisana wielkimi literami o tej samej nazwie; ustaw je, gdy zadania nie działają jako root) oraz wartości domyślne pól szczebla `send_schedule prune_schedule prefix pattern dst src autotune quiesce monitor_schedule gfs_pattern`. Retencja, progi i treść powiadomień są per szczebel i tutaj są odrzucane |
| `[relation:<name>]` | Cała polityka jednej relacji; zob. wyżej |
| `[template:<tier>]` | Pełna polityka jednego szczebla — rytm i retencja: `send_schedule`, `prefix`, `prune_schedule`, `pattern`, `keep` lub `retain`, `monitor_warn`/`monitor_crit`, `monitor_schedule`, `notify_word`, `tier_label`, `notify_raw`, ... Używają ich ręcznie pisane configi i profile |
| `[dataset:<path>]` | Dataset, którym zarządzasz od początku do końca. `use_template` lub `relation`, plus pola per dataset. Wykonuje create(+send/pull) i wbudowany self-prune ograniczony do własnej ścieżki (albo jej poddrzewa przy `recursive`). `dst` czyni z niego wysyłkę (ścieżka sekcji to lokalne źródło), `src = [user@]host:path` czyni z niego pobranie (ścieżka sekcji to lokalny cel i musi kończyć się dokładnie `path`); oba na jednej sekcji są odrzucane. Ponadto: `flags` (tylko tożsamość: `-K -k -O -p`), `flags_<tier>`, `send_schedule_<tier>`, `prune_schedule_<tier>`, `quiesce`, `autotune`, `pair_label` oraz pola łącza i zakresu `bandwidth`, `compression`, `cipher`, `history`, `raw`, `passive` (przejmij najnowszą istniejącą migawkę, `-e`), `exclude_family` (`-E`), `exclude_child_<n>` (`-X`, numerowane od 1), `media`, `prune_foreign` |
| `[prune:<scope>]` | Samodzielny, addytywny prune dla zakresów, których lokalnie **nie** tworzysz (magazyn kopii, źródło pobrania). `recursive=`/`clear_cut=` włączają `-R`/`-F`; `prune = no` czyni z sekcji wyłącznie nośnik strażnika; `ssh_flags` dla zakresu zdalnego (`host:path`); `gfs = yes` plus `gfs_pattern` łączą wszystkie szczeble w jedną drabinę `-G`. `[prune:]` nigdy nie wysyła, więc pola transferu są odrzucane |
| `[snaponly:<[user@]host:dataset>]` | Migawki na zdalnym źródle, robione przez `snapget.sh -s`, bez kopiowania czegokolwiek. Nazwa sekcji to źródło. Szczeble pochodzą z `use_template`; `pair_label` jest wymagane; ponadto `recursive`, `notify`, `notify_raw`, `ssh_flags`. Cel, flagi silnika i pola prune po stronie celu są odrzucane. Retencja źródła to `[prune:<scope>]` z `side = source` |
| `[replica:<name>]` | Kolejna kopia datasetu, który ten host już ma, zwykle na dysk wymienny. `source` (lokalne datasety, lista rozdzielona przecinkami), `dst` (bazowy dataset na nośniku, nigdy korzeń puli i nigdy zdalny), `schedule`, `prefix` lub `passive = yes`, `media = removable`, `media_guids`, `on_insert`, `recursive`, `keep`, `history`, `raw`, `flags`, `notify` oraz `monitor`/`monitor_warn`/`monitor_crit`. Nazwa tylko opisuje nośnik; źródło może mieć kilka replik |
| `[excluded:<prefix>]` | Ile **najnowszych** migawek z zarezerwowanym przez Proxmoxa prefiksem chronić, per dataset: `keep = <N>` lub `keep = all`. Dokłada `-P` do każdej linii prune migawek |
| `[prune-bookmarks:<scope>]` | Czyszczenie osieroconych bookmarków według wieku: `schedule`, `age` (surowe flagi wieku `delsnaps.sh`, wymagane), `pattern` (domyślnie `tgt-`), `recursive`, `ssh_flags` dla zakresu zdalnego, `notify` |

Nie ma osobnej sekcji `[monitor:]`. Sprawdzenie świeżości jest wyprowadzane automatycznie wszędzie
tam, gdzie `pattern` szczebla już się rozwiązuje na potrzeby prune, o ile ten szczebel ustawia też
`monitor_warn`/`monitor_crit` (oba albo żadne, a `pattern` jest wymagany). Używa tego samego
zakresu i rekursji, których potrzebował prune. Na zdalnym zakresie `[prune:]` sprawdzenie działa
przez ssh z `ssh_flags` tej sekcji (zob. `check-snap-age.sh`); odczyt, który się nie powiedzie, to
UNKNOWN strażnika („monitor BROKEN”), nigdy cichy OK. Tam, gdzie ten sam szczebel także wysyła,
`monitor_warn` musi być dłuższy niż najdłuższa przerwa między przebiegami tego szczebla (generator
przechodzi po prawdziwym kalendarzu według `send_schedule`: tydzień to 7 dni, miesiąc 31,
poniedziałek–piątek 72 godziny); próg równy lub niższy alarmowałby na zdrowym zadaniu w każdym
cyklu i jest odrzucany.

**`ssh_flags = <tylko -p/-k/-c/-K/-O>`** daje zdalnemu zakresowi sekcji `[prune:]` lub
`[prune-bookmarks:]` opcje ssh `delsnaps.sh` (port, known_hosts, szyfr, klucz prywatny, dodatkowe
`-o`). Jest celowo wąskie: `-R`/`-F`/`-B`/`-n` są odrzucane, bo mają własne pole
(`recursive=`/`clear_cut=`) albo własny typ sekcji (`-B` to właśnie `[prune-bookmarks:]`). Na zakresie
bez `:` jest to ostrzeżenie, a nie odrzucenie. Zastosowanie dla `[prune-bookmarks:]`: bookmarki
pobrania `snapget.sh` gromadzą się na *zdalnym* źródle, więc ich wyczyszczenie wymaga dotarcia do
tego hosta. Dwa zdalne zakresy, które mają ten sam harmonogram, wzorzec, wiek i rekursję, ale różne
`ssh_flags`, **nie** scalają się w jedną linię.

### Ręcznie pisane configi z szablonami

Sekcje `[template:]` z `use_template` pozostają poprawne w ręcznie pisanych configach (nie można ich
mieszać z `relation` w jednej sekcji). Używają ich także profile z katalogu `profiles/`. Ten
przykład wysyła dwa szczeble z jednego hosta:

```ini
[defaults]
host_label = src-a
dst        = hdd/backups/src-a

[template:hourly]
send_schedule    = 0 * * * *
prefix           = hourly_
pattern          = hourly_
keep             = 24
monitor_warn     = 90m
monitor_crit     = 3h

[template:daily]
send_schedule    = 30 2 * * *
prefix           = daily_
pattern          = daily_
keep             = 14
monitor_warn     = 26h
monitor_crit     = 48h

[dataset:rpool/data/vm-106-disk-0]
use_template = hourly,daily
notify       = vm106
quiesce      = agent
```

```bash
gen-cron.sh -c jobs.src-a.conf              # print the generated block for review
gen-cron.sh -c jobs.src-a.conf --install    # install it into this user's crontab
```

Zdalna sekcja prune w tym samym stylu:

```ini
[prune:root@10.0.0.9:hdd/pulled]
use_template = hourly
ssh_flags    = -p 2222 -k /etc/zfs-known-hosts -K /etc/zfs-backup-id_ed25519
notify       = pulled
```

### Co egzekwuje generator

- `flags="-f"` i `flags="-n"` są **odrzucane**: żadna z nich nie ma sensu w stałym, cyklicznym
  zadaniu (niszczenie i zakładanie od nowa w każdym przebiegu albo niewysyłanie niczego). `-r`/`-R`
  wewnątrz `flags` to także błąd; użyj `recursive =`.
- `-A` jest dodawane automatycznie do każdej wysyłki, której rozwiązane `dst` jest zdalne (zawiera
  `:`), chyba że `flags` już ustawia `-A` albo wprost nazywa kompresor, albo `autotune = no`.
- `-z`/`-Z`/`-g` na rozwiązanym **lokalnym** `dst` daje ostrzeżenie na stderr (nigdy błąd krytyczny),
  bo lokalne wysyłki i tak rezygnują z kompresji.
- Każda rozwiązana operacja prune jest porównywana z każdą inną na *tym samym* dosłownym zakresie:
  ponieważ `delsnaps.sh` dopasowuje po dosłownym prefiksie, wzorzec jednego szczebla będący
  prefiksem wzorca innego pozwoliłby jego migawkom przeciekać do cudzego przebiegu retencji, więc
  taki układ jest odrzucany.
- **Klucz obecny, ale pusty, jest traktowany dokładnie jak klucz nieobecny** dla `prefix`, `pattern`
  i `retain`/`keep`. Pusty `pattern` sprawiłby, że `delsnaps.sh` dopasuje każdą migawkę na zakresie,
  a pusty `retain` dałby linię bez flagi progu, która domyślnie działa w trybie wieku z progiem =
  teraz i kasuje niemal wszystko. Jedynym wyjątkiem jest `pattern` w `[prune-bookmarks:]`: pusta
  wartość wraca do domyślnego `tgt-`. `dst` zachowuje swoje uprawnione puste znaczenie (brak celu,
  tylko migawki).
- Pola tak/nie (`recursive`, `clear_cut`, `gfs`, `prune`, `passive`, ...) przyjmują wyłącznie `yes`
  lub `no`, w dowolnej wielkości liter; cokolwiek innego jest błędem, a nie cichym „no”.
- Datasety o tej samej rozwiązanej czwórce `(send_schedule, dst, prefix, flags)` scalają się
  w jedną linię wysyłki, a datasety o tej samej rozwiązanej czwórce `(prune_schedule, pattern,
  keep/retain, recursive)` scalają się w jedną linię prune, która wymienia je pełnymi ścieżkami.
  Rekursja nigdy nie jest domyślana ze wspólnego rodzica, a datasety pobierane (pull) nigdy się nie
  scalają. Dyski dwóch różnych strzeżonych gości PVE nie trafiają do jednej linii (strażnik gościa niżej).
- **Strażnik gościa PVE (`pve_guest_guard`, `pve_node`).** Linia, która robi albo przycina migawki
  na dysku gościa (`vm-N-disk-M`, `subvol-N-disk-M`) u źródła (wysyłka bez `-e`, pobranie,
  `[snaponly:]` i przycinanie tych samych datasetów), niesie `--pve-guests=<host>:<id>`. Przed
  uruchomieniem silnika `zfs-job.sh` sprawdza w `/etc/pve/nodes/<węzeł>/{qemu-server,lxc}/<id>.conf`,
  gdzie gość stoi. Gdy na innym węźle tego klastra: polecenie NIE rusza, END `rc=76`, alarm
  (dysk tu jest celem replikacji pvesr). Gdy host nie należy do klastra PVE albo gościa nie ma
  nigdzie: działa jak dotąd. Gdy host źródła jest adresem, którego nie da się przypisać do węzła
  (konto delegowane nie czyta `corosync.conf`): działa, a gdy gość jest w tym klastrze, daje
  ostrzeżenie; `pve_node = <węzeł>`
  w sekcji `[snaponly:]`/`[dataset:]` (pobranie) to rozstrzyga. Włączony sam;
  `pve_guest_guard = no` w `[defaults]`, `[dataset:]` albo `[snaponly:]` go wyłącza. Kopie
  pasywne (`-e`) i cele kopii nie są sprawdzane.
  **Drzewa** (1.0.1): linia rekurencyjna nad rodzicem, który nie jest dyskiem gościa (`rpool/data`,
  `hdd/vm-disks`), niesie `--pve-guests=<host>:tree`, a config zostaje jednym wpisem. Przy biegu
  `zfs-job.sh` listuje drzewo ŹRÓDŁA (`zfs list -r`; zdalne tymi samymi opcjami ssh co linia),
  z nazwy dysku (`vm-`/`subvol-`/`base-N-disk-M`) bierze numer gościa i sprawdza, gdzie gość stoi.
  Dysk gościa z innego węzła to replika pvesr: migawka `-R` (osobna migawka każdego datasetu)
  rusza z `-X` na dokładnie ten dysk i ostrzega; przycinanie i atomowe `-r` nie umieją pominąć
  dziecka, więc nie ruszają (`rc=76`, alarm). Zdalne drzewo, którego nie da się wylistować, rusza
  jak dotąd, z ostrzeżeniem. Cel kopii nie jest czytany.
- `recursive` steruje wszystkimi trzema wygenerowanymi liniami z jednej deklaracji: `no` = ten
  dataset, `flat` = `-R` przy transferze, `delsnaps -R`, `check-snap-age -R`; `atomic` = `-r` przy
  transferze z tym samym `-R` dla prune i strażnika.
- Każde polecenie w wygenerowanej linii przekierowuje własny stderr do logu crona, także wywołania
  notify, bo cron wysyła mailem wszystko, co zadanie zapisze na stdout lub stderr. Wszystko, co
  dopiszesz do takiej linii, potrzebuje własnego przekierowania.

### Sekcje prune tylko ze strażnikiem

`prune = no` daje strażnika bez drugiego prune. Rekursywne `[prune:hdd/backups]` już pokrywa każdy
liść pod sobą, ale progi strażnika są per szczebel, a liść, który jest ważniejszy od sąsiadów,
chce mieć własne. Dodanie `[prune:hdd/backups/src-a/nextcloud]` tylko po to, żeby zawiesić na nim
`monitor_warn`/`monitor_crit`, wygląda na niewinny duplikat, ale dwie linie `delsnaps.sh` startują
w tej samej minucie i **ścigają się**: przegrywająca znajduje migawkę już usuniętą i kończy się
kodem różnym od zera z komunikatem `could not find any snapshots to destroy` oraz mylącą wskazówką
o zależnych klonach. Własny `flock` w `delsnaps.sh` tego nie wyłapuje, bo klucz blokady jest hashem
listy datasetów i wzorca, a obie linie zasadnie się różnią (`-R parent` kontra jawny liść).

`prune = no` nie emituje linii `delsnaps` i zachowuje strażnika. Jest odrzucane, jeśli sekcja nie
ma wtedy `monitor_warn`/`monitor_crit`, bo nie wyemitowałoby niczego. Powyższe porównanie
krzyżowe zestawia wzorce tylko na *tym samym dosłownym zakresie*; zawieranie się zakresów
pozostaje twoją dyscypliną. Jeśli zadanie `delsnaps` zgłasza według harmonogramu „could not find
any snapshots to destroy”, poszukaj drugiej linii prune, której zakres zawiera ten dataset
i która startuje w tej samej minucie, zanim zaczniesz szukać klonów albo holdów.

### Drabina GFS w sekcji prune

Zakres `[prune:]` zabezpieczający dataset bez własnej konwencji nazewnictwa (zob.
[Kaskadowa drabina GFS](#drabina-kaskadowa-gfs)) potrzebowałby inaczej jednego szczebla
na każdy stopień, z których każdy emituje własną płaską linię `delsnaps.sh`. `gfs = yes` łączy
wszystkie szczeble z `use_template` w jedną linię `delsnaps.sh -G`:

```ini
[template:store_hourly]
prune_schedule = 51 * * * *
pattern        = automated_hourly
retain         = -H24
monitor_warn   = 90m
monitor_crit   = 3h

[template:store_daily]
prune_schedule = 53 0 * * *
pattern        = automated_daily
retain         = -D7

[template:store_weekly]
prune_schedule = 55 0 * * 0
pattern        = automated_weekly
retain         = -W4

[prune:backup/store]
use_template = store_hourly,store_daily,store_weekly
recursive    = yes
gfs          = yes
gfs_pattern  = automated_
notify       = store
```

Zamiast trzech linii powstaje jedna linia prune, według harmonogramu pierwszego wymienionego
szczebla:

```
51 * * * * ... delsnaps.sh -G -R "backup/store" "automated_" -H24 -D7 -W4 ...
```

Własny `retain` każdego szczebla musi rozwiązać się do dokładnie jednej flagi liczebności
(`-H`/`-D`/`-W`/`-M`/`-Y` z liczbą); `retain=` oparty na wieku albo napis z wieloma flagami jest
odrzucany przy `gfs = yes`. `gfs_pattern` to *osobne* pole od `pattern` każdego szczebla:
`pattern` szczebla nadal steruje jego własnym strażnikiem, a `gfs_pattern` jest szerszą siecią,
której połączona drabina potrzebuje, żeby zobaczyć migawki wszystkich szczebli. `pattern` każdego
szczebla musi zaczynać się od `gfs_pattern`; pominięcie pola daje drabinę bez prefiksu. Szczebel
z `prune = no` jest pomijany w połączonej drabinie, ale zachowuje swojego strażnika.

## Alerty

**Konfigurowalne per host, domyślnie jeden mail dziennie.** Każde ustalenie trafia do kolejki,
a `alert-digest.sh` raz dziennie wysyła jedno zgrupowane podsumowanie; jeśli o to poprosisz, każde
ustalenie przychodzi mailem w chwili, gdy się pojawi. Ustalenie idzie dokładnie jedną z tych dwóch
dróg, więc nigdy nie jest zgłaszane dwa razy. Tekst maili jest po polsku.

### Wybór rytmu

Jeden plik, `/etc/zfs-alert.conf`, wczytywany przez skrypty alertów jako zwykły shell (dawna
lokalizacja `/root/scripts/zfs-alert.conf` jest nadal czytana jako zapasowa). **Zmienną do zmiany
jest `ZFS_ALERT_MODE`.**

| Zmienna | Domyślnie | Znaczenie |
|---|---|---|
| `ZFS_ALERT_MODE` | `daily` | `daily` = kolejkuj każdy ALERT, jeden mail z podsumowaniem na host na dzień. **`immediate` = wysyłaj mailem każdy ALERT, gdy się pojawi** |
| `ZFS_WARN_MODE` | `daily` | Ten sam wybór dla ustaleń na poziomie WARNING, ustawiany osobno |
| `ZFS_ALERT_EMAIL` | ustawiane przy wdrożeniu | Dokąd trafiają alerty; zmienia wszystkie skrypty naraz |
| `ZFS_ALERT_COOLDOWN` | `14400` (4 h) | Tylko `immediate`: liczba sekund, zanim *ta sama* wiadomość może zostać wysłana ponownie. Ignorowane w `daily` (digest deduplikuje przez liczenie) |
| `ZFS_ALERT_STATE_DIR` | `/var/lib/zfs-snapshot-all/notify-state` | Tylko `immediate`: gdzie leżą znaczniki czasu cooldownu |
| `ZFS_ALERT_QUEUE` | `/var/lib/zfs-snapshot-all/alert-queue.log` | Tylko `daily`: kolejka, którą zużywa digest |
| `ZFS_DIGEST_DAYS` | `7` | Ile dni przebiegów obejmuje tabela digestu. Niezależne od tego, jak często wysyłany jest mail |
| `ZFS_DIGEST_QUIET` | `mon` | Kiedy host, który NIE MA nic do zgłoszenia, i tak wysyła pełny raport okresowy: `mon`..`sun`, `monthly` (1. dnia miesiąca), `1`..`28` (ten dzień miesiąca), `daily` albo `off`. Dzień z ustaleniami zawsze wysyła. `off` kosztuje gwarancję, że cisza oznacza martwy kanał |

**Pierwszeństwo**, od najwyższego: środowisko, potem `settings.ini`, potem `zfs-alert.conf`, potem
powyższe wartości domyślne. To, że środowisko wygrywa z plikiem, sprawia, że
`ZFS_ALERT_QUEUE=/tmp/q ./alert-digest.sh` jest bezpiecznym sposobem na próby. `settings.ini`
(`/etc/zfs-snapshot-all/settings.ini`, edytowany klawiszem F10 w GUI) mapuje się na te zmienne:

| `settings.ini` | Zmienna |
|---|---|
| `[alerts] email` | `ZFS_ALERT_EMAIL` |
| `[alerts] errors` | `ZFS_ALERT_MODE` |
| `[alerts] warnings` | `ZFS_WARN_MODE` |
| `[alerts] all_ok_mail` | `ZFS_DIGEST_QUIET` |
| `[alerts] stats_days` | `ZFS_DIGEST_DAYS` |
| `[alerts] repeat_after` | `ZFS_ALERT_COOLDOWN` (liczba sekund albo `30m`, `4h`) |
| `[capacity] threshold` | `ZFS_CAPACITY_THRESHOLD` |
| `[capacity] guard`, `guard_at`, `guard_target`, `guard_min_keep` | `ZFS_GUARD*` (strażnik pojemności) |
| `[growth] alert`, `factor`, `min_mib`, `max_ratio_pct`, `days` | `ZFS_GROWTH_*` (strażnik przyrostu) |

`deploy.sh` zapisuje `/etc/zfs-alert.conf` jednorazowo, z opisem każdego klucza, i nigdy go nie
nadpisuje, więc ręcznie edytowany tryb przeżywa każde ponowne uruchomienie i aktualizację; host
wdrożony, zanim dany klucz istniał, nadal go przyjmuje — brakuje tylko komentarza.

```bash
sed -i 's/^ZFS_ALERT_MODE=.*/ZFS_ALERT_MODE=immediate/' /etc/zfs-alert.conf
```

**Ustaw `immediate`, gdy uruchamiasz host.** Zadanie źle skonfigurowane dziś to pięć minut
poprawki, jeśli dowiesz się o nim w ciągu godziny, i stracona noc backupów, jeśli przeczytasz o nim
w jutrzejszym digeście. Wdróż host w ten sposób przez `bash deploy.sh --alerts=immediate`, a po
kilku dniach czystej pracy hosta przełącz na `daily`.

Config leży w `/etc`, a kolejka w `/var/lib/zfs-snapshot-all/` (`2775 root:zfsalert`, setgid),
a nie w `/root/scripts`, ponieważ `/root` ma `0700`: delegowane konto nie-root nie może tam nic
czytać ani zapisywać. Otwarcie `/root/scripts` dla grupy byłoby eskalacją uprawnień, bo root
wykonuje te skrypty z crona. Katalog współdzielony trzyma więc wyłącznie dane; skrypty pozostają
prywatne dla każdego konta, a deploy daje koncie serwisowemu własne kopie `notify-fail.sh`
i `notify-warn.sh` wskazujące tę samą kolejkę. `alert-digest.sh` nie jest powielany: działa jako
root na wspólnej kolejce, więc host nadal wysyła jeden mail dziennie obejmujący oba konta.
*Harmonogram* digestu to linia crona emitowana przez `gen-cron.sh` (`DIGEST_SCHEDULE`, domyślnie
`0 7 * * *`).

**Dlaczego domyślne jest `daily`.** Przy mailach natychmiastowych cooldown jest kluczowany po
*wiadomości*, więc każde odrębne ustalenie ma własny licznik, a dwa zadania, które zawodzą w tym
samym takcie crona, wysyłają dwa maile w tej samej sekundzie. Liczba maili rośnie wraz z liczbą
odrębnych ustaleń, a nie hostów, a w całej flocie jest to strumień, który operator zaczyna
odfiltrowywać, co jest gorsze niż jedno dzienne podsumowanie, które się czyta. Kosztem jest to, że
pilne ustalenie czeka do uruchomienia digestu. Nie dotyczy to sprzętu: mail o kondycji puli z ZED
samego Proxmoxa to osobny mechanizm, którego ten projekt nie rusza, więc wypadnięcie dysku nadal
alarmuje natychmiast. Cichy dzień oznacza „nic nie trafiło do kolejki”, a nie „zdrowo”, bo martwy
cron też milczy; z tego powodu istnieje okresowy mail „wszystko OK” (`ZFS_DIGEST_QUIET`).

### Kolejka, digest i skrypty notify

Te skrypty leżą w [`hostscripts/`](../../hostscripts), a `deploy.sh` instaluje je przez kopiowanie,
więc „aktualny” znaczy bajt w bajt identyczny z checkoutem. `gen-cron.sh` wpina dwa pierwsze
bezpośrednio w każdą wygenerowaną linię strażnika (`[ $rc -eq 1 ] && notify-warn.sh ...; [ $rc -eq 2 ] &&
notify-fail.sh ...; [ $rc -ge 3 ] && notify-fail.sh ...`).

| Skrypt | Zapisuje | Jak |
|---|---|---|
| `notify-fail.sh` | Każde zadanie zwracające kod różny od zera (awaria `snapsend`/`snapget`/`delsnaps`), `check-snap-age.sh` CRITICAL/UNKNOWN albo pulę, która nie jest ONLINE | `daily`: dopisuje `epoch<TAB>ALERT<TAB>label<TAB>detail` do kolejki i nie wysyła maila. `immediate`: wysyła mail od razu, z limitem częstotliwości per wiadomość |
| `notify-warn.sh` | `check-snap-age.sh` WARNING (robi się nieświeże, jeszcze nie CRITICAL) | Ta sama kolejka z poziomem `WARN`, zgodnie z `ZFS_WARN_MODE` |
| `alert-digest.sh` | | Jedyny mail o backupie, jaki host wysyła w trybie `daily`. Raz dziennie wysyła jedną wiadomość z tematem `[ZFS] <host> <date> STAN: OK\|UWAGA -- N alert / M warn`. Pierwszy blok to stan *teraz* (pule oraz tabela zadań z okna `ZFS_DIGEST_DAYS`); drugi to to, co *się wydarzyło*: najpierw ustalenia ALERT, potem WARNING, a po każdym to, co ustalenie faktycznie mówiło. Cichy dzień ma inny temat (`... cisza, kanal sprawny (raport okresowy)`), żeby nie dało się go pomylić z mailem z ustaleniami. Jeśli `mail` zawiedzie, ustalenia wracają do kolejki, a skrypt kończy się kodem różnym od zera |
| `check-pool-capacity.sh` | Pulę albo dataset z refquota zbliżającą się do zapełnienia, zanim jakiekolwiek zadanie przez to zawiedzie. Zgłasza przez `notify-fail.sh`, więc trafia do tego samego digestu | Cron, domyślny próg 90% (`ZFS_CAPACITY_THRESHOLD`) |
| `capacity-guard.sh` | Opcjonalny (domyślnie `off`): gdy pula przekroczy `ZFS_GUARD_AT` (domyślnie 89%), usuwa wyłącznie migawki, które można bezpiecznie usunąć: te należące do lokalnych linii `delsnaps` tego hosta, nigdy z holdem, nigdy najnowszą migawkę datasetu. Każda wątpliwość oznacza, że nie usuwa nic | `[capacity]` w `settings.ini` |
| `growth-guard.sh` | Opcjonalny (domyślnie `off`), tylko alert: oznacza przyrost będący wielokrotnością (`ZFS_GROWTH_FACTOR`, domyślnie 5) niedawnej normy datasetu, a przy tym słabo kompresowalny, co jest sygnaturą masowego szyfrowania plików. Niczego nie usuwa i niczego nie wstrzymuje | `[growth]` w `settings.ini` |

**Co niesie ustalenie.** Sama etykieta (`src-a hourly getting stale (vm-archive)`) to napis z twojego
configu: identyfikuje zadanie i nic więcej. Dlatego ustalenie podróżuje z tekstem, który faktycznie
wytworzyło zadanie albo strażnik: strażnicy przekazują linię werdyktu `check-snap-age.sh` (dataset,
wzorzec, najnowsza migawka, wiek, progi), a nieudane zadania przekazują ostatnie 8 linii swojego
stderr (nadal dopisywanych do `cron.log`). Kolejka ma cztery kolumny rozdzielone tabulatorami
(epoch, poziom, etykieta, szczegół); starsze linie trzykolumnowe są pokazywane bez szczegółu.
Ustalenie pozostaje jedną linią, żeby równoległe dopisywania pozostały atomowe: tabulatory
w szczególe zamieniają się na spacje, a znaki nowej linii na `\001`, które digest zamienia z powrotem
na nowe linie. Pokazywany szczegół pochodzi z **ostatniego** wystąpienia, bo przy czymś, co odpala
się co piętnaście minut, najświeższy odczyt opisuje stan teraz. Skutkiem ubocznym jest to, że
wyjście zadania trafia do `cron.log` jako jeden ciągły blok po jego zakończeniu, co zarazem
powstrzymuje dwa nakładające się zadania przed przeplataniem linii.

`notify-fail.sh`, `notify-warn.sh` i `alert-digest.sh` czytają wspólną preambułę
`hostscripts/alert-env.sh`, którą `deploy.sh` instaluje obok nich.

### Kondycja puli

`snapsend.sh`/`snapget.sh` sprawdzają pulę ZFS stojącą za każdym datasetem, którego dotykają, przez
`check_pool_health()` w `lib-zfs-snap.sh`: stronę zawsze lokalną bezwarunkowo, a stronę zdalną
także wtedy, gdy transfer jest zdalny, przez połączenie, które transfer i tak otwiera. Pula, która
nie jest `ONLINE`, jest zgłaszana przez `notify-fail.sh` (czyli w trybie `daily` trafia do kolejki
digestu jak każdy inny ALERT, a w trybie `immediate` jest wysyłana mailem pod zwykłym cooldownem),
ze szczegółem w postaci pierwszych linii `zpool status`. Sprawdzenie jest celowo niezależne od kodu
wyjścia transferu: pula `DEGRADED` z ocalałą nogą lustra nadal wysyła bez problemu, więc powiązanie
alertu z powodzeniem transferu ukryłoby prawdziwą awarię dysku za kodem wyjścia „zadanie się
udało” albo zgłosiłoby działający transfer jako nieudany. Ponieważ sprawdzenie działa od strony,
która otwiera połączenie, jedno wykonanie zgłasza oba końce wysyłki lub pobrania; druga strona nie
potrzebuje własnego crona kondycji puli. Peer, którego bramka parowania odrzuca relację
(`disable-client`), jest logowany jako „could not be checked” i nie wywołuje alertu o puli:
blokada administracyjna to nie awaria storage.

### Rotacja logów

`/etc/logrotate.d/zfs-snapshot-all` (logi roota) i `/etc/logrotate.d/zfs-snapshot-all-<user>`
(logi konta serwisowego) są dostarczane ze skryptem deploy: miesięcznie, 24 zachowane, kompresja.
Są dwie stanzy z powodu `create`: rotacja logów konta serwisowego do pliku należącego do roota
pozostawiłaby to konto bez możliwości dopisywania. Żadna nie używa globu `*.log`, bo kolejka
alertów leży w tym samym katalogu i jest stanem, a nie logiem. Retencja jest celowo długa, ponieważ
diagnozowanie problemu z backupem oznacza porównywanie przebiegów sprzed tygodni, a ilość danych to
około 0,1 MB dziennie.

## deploy.sh (przygotowanie hosta)

Jeden skrypt na host, uruchamiany jako root, idempotentny, bezpieczny do ponownego uruchomienia.
Obsługuje też parowanie peerów (`--pair`, `--join`, `--leave`, `--unpair`, `--draft-scope`,
`--commit-scope` oraz czasowniki konserwacyjne `--pause`/`--resume` i
`--self-update`/`--rollback`/`--resume-updates`); zwykle wywołuje je za ciebie `zfs-backup.sh`,
a opisane są w [WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md) i w `deploy.sh --help`.

```bash
bash deploy.sh                          # host setup; maintains an existing account if found
bash deploy.sh --check-only             # audit the WHOLE host, change nothing
bash deploy.sh --alerts=immediate       # mail every finding; use while bringing a host up
bash deploy.sh --backup-user=zfsbackup  # also CREATE the delegated non-root account
```

Wartości domyślne leżą w bloku konfiguracyjnym na początku skryptu (`NOTIFY_EMAIL`, `ALERT_MODE`,
`BACKUP_USER`, `BACKUP_USER_DATASETS`); edytuj je, żeby wybór był trwały dla hosta, albo przekaż
flagę na jedno uruchomienie. `--email=ADDR` ustawia adres alertów, a `--test-mail` wysyła
próbny mail sprawdzający dostarczanie (automatycznie tylko przy pierwszej konfiguracji).

**`BACKUP_USER` dotyczy tworzenia, nie utrzymania.** Pozostawione puste, istniejące delegowane
konto jest nadal wykrywane automatycznie i utrzymywane w aktualnym stanie (jego skrypty notify,
rotacja logów, członkostwo w grupach); o *utworzenie* trzeba poprosić. Samo `bash deploy.sh` jest
więc właściwym poleceniem na każdym hoście we flocie, niezależnie od tego, czy ma konto.

- **Kroki 1 do 7 (zawsze)** przygotowują host Proxmox/Debian jako **root**: (1) sprawdzenie lub
  instalacja każdej zależności uruchomieniowej, (2) sklonowanie lub aktualizacja checkoutu
  w `/root/scripts/zfs-snapshot-all`, (3) współdzielony stan alertów, (4) skrypty notify i digest,
  (5) alerty o pojemności, (6) test dymny dostarczonych plików wykonywalnych plus próba
  „w obie strony” żywego kompresora oraz (7) linia crona z auto-pull. Celowo **nie** rusza twoich
  rzeczywistych linii zadań `snapsend`/`snapget`/`delsnaps`: te są per host i należą do
  `zfs-backup.sh` albo `gen-cron.sh`.
- **Krok 8 (opcjonalny)** przygotowuje dedykowane, delegowane konto **nie-root** (sugerowana nazwa
  `zfsbackup`), żeby replikacja nie wymagała roota: konto z zablokowanym hasłem, tylko z kluczem
  SSH, własny lock i katalog stanu, własny checkout i własna linia crona z auto-pull oraz delegacja
  `zfs allow` na datasetach podanych przez `--grant-datasets` (alias `--datasets`; domyślnie
  `rpool/data rpool/ROOT/pve-1`, standardowy układ Proxmoxa; nadpisz na każdym hoście, który od
  niego odbiega). Delegacja na datasecie (zwykłe `zfs allow`, nie `zfs allow -d`) obejmuje też
  potomków, które jeszcze nie istnieją, więc nowe dyski VM/CT tworzone później pod `rpool/data`
  ją dziedziczą. `--allow-quiesce` dodatkowo pozwala temu kontu zamrażać gości, których dyski leżą
  pod tymi datasetami; `--revoke-quiesce` to cofa.

  Na Linuksie delegowane uprawnienie `mount` nadal nie pozwala montować ani odmontowywać bez
  `CAP_SYS_ADMIN`. Rutynowa replikacja przyrostowa jest tym nietknięta, a ponieważ każdy poziom
  ścieżki celu (nie tylko liść) jest tworzony jako `canmount=noauto`, konto może zainicjować od zera
  zupełnie nową, wielopoziomową ścieżkę celu. Root nadal jest potrzebny do: `-f` oraz `-F` na
  aktualnie zamontowanym celu lub klonie; oba wypisują wskazówkę odsyłającą tutaj, gdy zawiodą
  z tego powodu.

  **Ścieżki idą za kontem.** Uruchomione jako nie-root, `STATS_LOG`, `NOTIFY_SCRIPT` i `LOCKDIR`
  domyślnie wskazują na `$HOME/zfs-snapshot-stats.log`, `$HOME/notify-fail.sh` i `$HOME/run`
  zamiast na odpowiedniki pod `/root`, który ma `0700`. Jawna zmienna środowiskowa nadal wygrywa.
  W configu `gen-cron.sh` z tego samego powodu ustaw w `[defaults]` `repo_dir`, `notify_script`,
  `warn_script`, `digest_script` i `cron_log`.

  ```bash
  bash deploy.sh --backup-user=zfsbackup                        # default datasets
  bash deploy.sh --backup-user=zfsbackup --datasets="rpool/data tank/vm"
  ```

## Przykłady z praktyki

### 1. Od zera do działającego harmonogramu hourly/daily z ręcznie pisanym configiem

To jest droga ręczna; normalna droga to `zfs-backup.sh` (zob.
[WDROZENIE-PROXMOX.md](WDROZENIE-PROXMOX.md)).

```bash
# On the new host, as root:
bash deploy.sh

# Write /root/scripts/zfs-snapshot-all/jobs.$(hostname -s).conf (see the template
# example under gen-cron.sh), then:
cd /root/scripts/zfs-snapshot-all
./gen-cron.sh -c "jobs.$(hostname -s).conf"           # review the generated block
./gen-cron.sh -c "jobs.$(hostname -s).conf" --install # install it
crontab -l                                            # confirm the managed block landed
./gen-cron.sh -c "jobs.$(hostname -s).conf" --reconcile  # does every dataset have a send job?
```

`gen-cron.sh` już dodał `-A` do zdalnych linii wysyłki i odrzucił każde `-f`/`-n` wpisane do
`flags`. Sprawdzenia świeżości dla każdego szczebla, który ustawił `monitor_warn`/`monitor_crit`,
jadą w tym samym bloku crontaba.

### 2. Zdalna wysyłka z kompresją, autotune i zamrażaniem gościa

Dysk VM, replikowany na zdalny host, z zamrożeniem gościa (quiesce) dla czystego obrazu na
konkretny moment:

```bash
./snapsend.sh -q agent -A rpool/data/vm-107-disk-0 backup@offsite.example:tank/backups/src-a
```

`-A` mierzy prawdziwe łącze do `offsite.example` i kompresowalność tego datasetu, zanim zdecyduje,
czy kompresować. `-q agent` zamraża VM 107 przez jego qemu-guest-agent dokładnie na czas wywołania
`zfs snapshot` i odmraża go, zanim ruszy transfer, więc zamrożenie nigdy nie nakłada się na
(potencjalnie znacznie dłuższą) wysyłkę. Jeśli zamrożenie się nie powiedzie, migawka i tak zostaje
wykonana, nazwana `..._crash_...`, a przebieg kończy się kodem 8; dodaj `,strict`
(`-q agent,strict`), żeby zamiast tego odmówić.

### 3. Replikacja przez pobranie jako delegowany użytkownik nie-root

Na kolektorze jedno polecenie tworzy delegowane konto, deleguje mu cel, paruje ze źródłem
i instaluje zadania w crontabie tego konta:

```bash
./zfs-backup.sh --source=src-a:rpool/data --target=hdd/backups --local-user=zfsbackup --install
```

Klucze i przypięty klucz hosta są wymieniane przez parowanie, a nie ręcznie. Konto ma delegację
`zfs allow` na cel (i na wszystko, co zostanie pod nim później utworzone), więc odbiera przyrosty
bez roota, łącznie z zupełnie nową, wielopoziomową ścieżką celu; `-f` albo `-F` na zamontowanym
klonie nadal wymaga roota. Aby uruchomić zadanie ręcznie jako to konto, skopiuj polecenie silnika
z `crontab -l -u zfsbackup`: linia niesie potrzebne `-K` i `-k` i działa dokładnie tak, jak uruchamia ją cron.

### 4. Przetrwanie zmiany nazwy (dopasowanie po GUID)

```bash
./snapsend.sh -e tank/data backup/tank/data     # first sync: lands @a

zfs rename backup/tank/data@a backup/tank/data@archived   # admin tidies up the target
zfs snapshot tank/data@b

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

Szybka ścieżka oparta na nazwie nie znajduje dopasowania (cel nie ma migawki dosłownie o nazwie
`@a`), ale zapasowe dopasowanie po GUID rozpoznaje `@archived` jako tę samą migawkę według
tożsamości ZFS, więc pozostaje to prawdziwym przyrostem (`@archived` zostaje, `@b` jest dołączana),
a nie cofnięciem w stylu `-f`, które wymazałoby `@archived` z celu.

### 5. Wyjście z sytuacji, gdy migawka źródła została przycięta za wcześnie

```bash
./snapsend.sh -e tank/data backup/tank/data     # sync #1, bookmark refreshed for this target

zfs destroy tank/data@a                         # delsnaps.sh (or a human) prunes the source snapshot
zfs snapshot tank/data@c

./snapsend.sh -e tank/data backup/tank/data     # exits 0
```

Gdy `@a` zniknęła ze źródła, szybkie ścieżki po nazwie i po GUID nie znajdują nic wspólnego, ale
`find_bookmark_base()` odnajduje odświeżony bookmark `tank/data#tgt-<hash>`, której GUID zgadza się
z aktualną głową celu, i wysyła `-i <bookmark> @c` zamiast wracać do pełnej ponownej wysyłki.

### 6. Dwa niezależne harmonogramy lądujące w tym samym celu

```bash
./snapsend.sh -e -j hourly  tank/data backup/tank/data
./snapsend.sh -e -j offsite tank/data backup/tank/data
```

Bez `-j` dzieliłyby jeden lock (więc nakładanie się szeregowałoby się, a nie ścigało, co samo
w sobie jest poprawne) i jeden bookmark (więc ta, która ruszyła ostatnia, po cichu stałaby się
jedyną z ważną bazą przyrostu). Przy odrębnych tagach każde zadanie ma własny lock i własną
bookmark `tgt-<hash>`, więc na obu można polegać niezależnie.

### 7. Sprzątanie bookmarków po wycofanym celu

Trzy miesiące temu wycofano VM; jej bookmark na źródle od tamtej pory leży nietknięta. W configu:

```ini
[prune-bookmarks:tank/data]
schedule  = 0 4 * * 0
age       = -d30
recursive = yes
```

`gen-cron.sh --install` zamienia to w cotygodniowe `delsnaps.sh -B -R "tank/data" "tgt-" -d30`:
wszystko, co nie było odświeżane od 30 dni lub dłużej (z dużym zapasem ponad każdy realny cykl
backupu), jest przycinane.

### 8. Przerwany transfer wznawia się sam

Duża początkowa wysyłka na zdalny host urywa się w trakcie strumienia (chwilowy zanik sieci,
restart hosta):

```bash
./snapsend.sh tank/data user@host:backup/tank/data   # dies partway through
```

Cel zostaje z `receive_resume_token`. Nic nie trzeba robić ręcznie: *następne* zaplanowane
(albo ręczne) uruchomienie tego samego polecenia wykrywa token przez `get_resume_token()` i wznawia
przez `zfs send -t <token>`. Jeśli wznowienie nie powiedzie się 3 razy z rzędu, następne
uruchomienie czysto się poddaje (`zfs receive -A`, odrzucając wyłącznie utknięty stan częściowy)
i wraca do zwykłej wysyłki przyrostowej lub pełnej.

### 9. Przerzedzanie lat migawek bez wzorca do wieży GFS

Dataset jest migawkowany co godzinę od miesięcy bez prefiksu `-m`, więc przycinanie `delsnaps.sh`
oparte na wzorcu nie ma się czego uchwycić. Płaski prune według liczby potrzebowałby jednego
zadania na szczebel; `-G` zwija to w jedno:

```bash
# Preview first: how many would actually go, and does the shape look right?
./delsnaps.sh -n -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3

# Looks right, run it for real:
./delsnaps.sh -G -R "hdd/backups" "" -H24 -D7 -W4 -M12 -Y3
```

Pusty wzorzec (`""`) dopasowuje każdą migawkę na zakresie; `-G` zmienia tylko to, co dzieje się
z tym dopasowanym zbiorem. Zamiast jednego płaskiego „zachowaj 50 najnowszych” wieża zachowuje 24
po jednej na godzinę, potem 7 po jednej na dzień zaraz za nimi, potem 4 po jednej na tydzień, 12 po
jednej na miesiąc i 3 po jednej na rok, przy czym każdy szczebel zaczyna tam, gdzie kończy się
pokrycie poprzedniego. Dataset, który naprawdę był migawkowany co godzinę przez cały czas, kończy
blisko sumy z liczby płaskiej tak czy owak; dataset o nieregularnej historii (seria dodatkowych
migawek jednego dnia, potem tydzień ciszy) dostaje dokładnie jedną ocalałą na każdy przedział,
którego dane faktycznie dosięgły, i tu oba schematy się rozchodzą, czasem znacznie. Przed
przełączeniem działającego zadania retencji z płaskich liczb na `-G` wykonaj próbę (dry-run)
**obu** i porównaj ich zbiory „would delete”: na nieregularnych danych wieża może zająć migawki,
których płaska liczba nigdy by nie ruszyła.
