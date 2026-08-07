# Wdrożenie na Proxmox — instrukcja krok po kroku

Dla administratora, który zna Linuksa i podstawy ZFS, ale ten pakiet widzi
pierwszy raz. Nie zakładamy znajomości wewnętrznej architektury — zakładamy, że
umiesz czytać `zfs list` i edytować plik w `vi`.

Wersja angielska: [DEPLOYMENT-PROXMOX.md](DEPLOYMENT-PROXMOX.md).

---

## 1. Model, który wdrażamy

Dwa hosty Proxmox VE, **bez żadnego wcześniejszego zaufania** między nimi (nie
są w jednym klastrze, nie mają wymienionych kluczy SSH).

| Rola | Nazwa w przykładzie | Adres | Co robi |
|---|---|---|---|
| **Kolektor** | `pve-backup` | `192.168.1.10` | trzyma kopie, zarządza całością, **inicjuje połączenie** |
| **Źródło** | `pve-prod` | `192.168.1.20` | produkcja, oddaje dane, nic nie inicjuje |

Na źródle leżą typowe dla Proxmoksa datasety:

```
rpool/data/vm-100-disk-0      <- produkcyjna VM
rpool/data/vm-101-disk-0      <- produkcyjna VM
rpool/data/vm-999-disk-0      <- maszyna testowa, NIE chcemy jej w kopii
rpool/data/scratch            <- katalog roboczy
rpool/data/scratch/tmp-a        (i jego dzieci)
```

Na kolektorze kopie mają lądować pod `rpool/backups`.

### Dwie fundamentalne zasady, które warto zrozumieć od razu

**Kierunek: kolektor CIĄGNIE (pull).** To `pve-backup` łączy się do
`pve-prod`, nie odwrotnie. Konsekwencja bezpieczeństwa jest zasadnicza:
**włamanie na produkcję nie daje dostępu do kopii.** Serwer produkcyjny nie ma
żadnego klucza do kolektora i nie wie nawet, jak się tam dostać. Ransomware,
który zaszyfruje `pve-prod`, nie ma drogi do `rpool/backups`.

**Podział decyzji: źródło decyduje CO, kolektor decyduje JAK.** Listę
datasetów wybiera administrator *na maszynie źródłowej* — tam, gdzie wiadomo,
co jest czym. Harmonogram i retencję ustala kolektor. Dzięki temu nikt nie musi
zgadywać cudzego układu dysków.

---

## 2. Zanim zaczniesz

Na **obu** hostach:

- Proxmox VE z pulą ZFS (`rpool`),
- dostęp roota po SSH (na czas wdrożenia; docelowo zadania chodzą z konta
  delegowanego),
- łączność sieciowa kolektor → źródło (port 22 lub własny).

Wymagane pakiety (`zfs`, `mbuffer`, `zstd`) **doinstaluje `deploy.sh` sam** —
nie musisz tego robić ręcznie.

Sklonuj repozytorium na oba hosty, w to samo miejsce:

```bash
git clone https://github.com/AdalbertKing/zfs-snapshot-all.git /root/zfs-snapshot-all
```

> **Nigdy nie kopiuj skryptów przez `scp`/`pscp` na hosty.** Aktualizacje
> chodzą przez `git pull --ff-only` co godzinę. Plik podmieniony ręcznie
> zabrudzi drzewo i **trwale zablokuje automatyczne aktualizacje** na tym
> hoście — cicho, bez alertu.

---

## 3. Procedura wdrożenia

Każdy krok ma wyraźnie zaznaczone, **na którym hoście** się go wykonuje.
Kolejność jest obowiązkowa.

### Krok 1 — przygotowanie kolektora `pve-backup`

```bash
cd /root/zfs-snapshot-all
./zfs-backup.sh setup-server --target=rpool/backups --local-user=zfsbackup
```

Co się dzieje: instalują się zależności, powstaje konto delegowane
`zfsbackup`, zakładany jest dataset `rpool/backups`, powstaje plik konfiguracji
zadań i wpis crona z automatyczną aktualizacją.

`--local-user=zfsbackup` znaczy: **zadania backupu nie będą chodzić z roota.**
Warto — to ogranicza szkody, gdyby cokolwiek poszło nie tak.

Sprawdź, że jest czysto:

```bash
./deploy.sh --check-only
```

### Krok 2 — zgłoszenie klienta (nadal `pve-backup`)

```bash
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=backup
```

- `prod01` — trwała nazwa tej relacji. **Nie zmieni się nigdy**, nawet gdy
  źródło zmieni adres IP. Używaj jej we wszystkich późniejszych komendach.
- `--mode=backup` — mówi: „nie wypisuję tu listy datasetów, wybierze ją
  administrator źródła". To jest ta ścieżka, którą chcesz. (Wariant `sync` —
  patrz rozdział 6.)

Komenda wypisze **ścieżkę do paczki parującej** (plik `.tgz`) i dokładne
polecenie do uruchomienia na źródle. Zapisz je.

Paczka nie zawiera żadnych sekretów kolektora — zawiera klucz publiczny i
parametry relacji.

### Krok 3 — przeniesienie paczki na źródło

Skopiuj plik `.tgz` na `pve-prod` dowolną drogą (`scp` z Twojej stacji
roboczej, pendrive, cokolwiek). To jedyny moment, gdy coś przenosisz ręcznie.

### Krok 4 — przyjęcie parowania na źródle `pve-prod`

```bash
cd /root/zfs-snapshot-all
./deploy.sh --join=/root/prod01-package.tgz
```

Powstaje dedykowane konto dla tej jednej relacji, z zainstalowanym kluczem
kolektora i — to ważne — **z zerowymi uprawnieniami do ZFS.**

To jest bezpieczny stan pośredni, nie niedoróbka: kolektor może się już
połączyć i zrobić `zfs list` (listowania `zfs allow` nie ogranicza), ale nie
może odczytać ani bajta danych, dopóki świadomie tego nie nadasz w kroku 6.

Komenda wypisze **LABEL** — etykietę tej relacji, potrzebną w dwóch kolejnych
krokach. Dla `--lan=192.168.1.20` etykietą będzie `192.168.1.20`.

### Krok 5 — wygenerowanie pliku zakresu (`pve-prod`)

```bash
./deploy.sh --draft-scope=192.168.1.20
```

Powstaje `/etc/zfs-snapshot-all/peers/192.168.1.20.scope` — wygenerowany z
**prawdziwego** inwentarza ZFS tej maszyny, nie zgadnięty. W środku:
propozycja aktywnych sekcji plus pełna lista datasetów jako komentarz, z której
możesz dopisywać.

### Krok 6 — wybór datasetów i wykluczeń (`pve-prod`)

**To jest jedyny krok wymagający myślenia.** Edytujesz plik:

```bash
vi /etc/zfs-snapshot-all/peers/192.168.1.20.scope
```

Gramatyka ma cztery pola i żadnej magii:

| Pole | Znaczenie |
|---|---|
| `include_parent` | czy brać **sam** wymieniony dataset |
| `include_children` | czy brać **wszystko pod nim** |
| `exclude` | pomiń **dokładnie ten jeden** dataset |
| `exclude_tree` | pomiń ten dataset **i wszystko poniżej** |

#### Wariant A — z rekurencją i wykluczeniami (typowy)

Bierzemy wszystkie dyski VM spod `rpool/data`, ale bez maszyny testowej i bez
całego katalogu roboczego:

```ini
[dataset:rpool/data]
    include_parent   = no
    include_children = yes
    exclude          = rpool/data/vm-999-disk-0
    exclude_tree     = rpool/data/scratch
```

Czytaj to tak: *„sam `rpool/data` mnie nie interesuje (to kontener, nie dane),
wszystko pod nim tak, oprócz tej jednej maszyny i oprócz całej gałęzi
`scratch`."*

Efekt — objęte kopią zostaną `vm-100-disk-0` i `vm-101-disk-0`. Pominięte:
`vm-999-disk-0`, `scratch` i wszystkie jego dzieci.

#### Wariant B — bez rekurencji (wybór ręczny)

Gdy chcesz dokładnie wskazać, co ma być kopiowane, i nic więcej:

```ini
[dataset:rpool/data/vm-100-disk-0]
    include_parent   = yes
    include_children = no

[dataset:rpool/data/vm-101-disk-0]
    include_parent   = yes
    include_children = no
```

Tu `include_parent = yes` znaczy „ten konkretny dataset", a
`include_children = no` — „i nic pod nim" (dyski VM zwykle i tak nie mają
dzieci).

**Który wybrać?** Wariant A, jeśli reguła brzmi „wszystkie maszyny z tej puli".
Wariant B, jeśli backupujesz wybrane maszyny, a reszta świadomie zostaje poza.
Zwróć uwagę na ograniczenie opisane w rozdziale 7 — ono może przeważyć wybór.

Plik jest czytany jako **dane, nigdy jako kod**. Literówka, nieznane pole czy
zdublowana sekcja = odmowa z numerem linii i powrót do edycji, nie połowiczne
wdrożenie.

### Krok 7 — nadanie uprawnień (`pve-prod`)

```bash
./deploy.sh --commit-scope=192.168.1.20
```

Dopiero **teraz** konto kolektora dostaje uprawnienia ZFS — i dokładnie do
tego, co wybrał plik z kroku 6.

To celowo osobna, świadoma komenda: plik zakresu edytuje się często i z
pomyłkami, a nadanie uprawnień ma być jednym, przemyślanym aktem. Przed
wykonaniem zobaczysz **cały plan** (co zostanie nadane, co odebrane), a nie
odkrywanie go po drodze.

Ponowne uruchomienie po edycji pliku **także odbiera** to, czego nowy zakres
już nie obejmuje — ale wyłącznie w granicach tej relacji. Grant nadany przez
kogoś innego albo ręcznie jest dla tej komendy niewidzialny i pozostaje
nietknięty.

### Krok 8 — pierwsza kopia (wracamy na `pve-backup`)

```bash
./zfs-backup.sh seed prod01
```

Pełny transfer bazowy. Trwa tyle, ile trwa przesłanie danych — dla kilkuset GB
przez gigabit licz w godzinach. Można spokojnie puścić w `screen`/`tmux`.

### Krok 9 — weryfikacja połączenia (`pve-backup`)

```bash
./zfs-backup.sh verify-endpoint prod01
```

Potwierdza, że adres, którym połączenie faktycznie chodzi, działa i jest ten,
o którym myślisz. **Cron nie zostanie zainstalowany, dopóki ten krok nie
przejdzie** — to celowa bramka, nie formalność.

### Krok 10 — uruchomienie (`pve-backup`)

```bash
./zfs-backup.sh activate-client prod01
```

Dopiero teraz powstają wpisy w cronie. Od tej chwili backup chodzi sam.

### Krok 11 — sprawdzenie

```bash
./zfs-backup.sh status
./zfs-backup.sh test prod01
zfs list -r rpool/backups
```

Stan `active` = gotowe.

---

## 4. Gdzie wylądują dane (wariant `backup`)

Ścieżka docelowa składa się z: **cel + etykieta relacji + pełna ścieżka
źródłowa**:

```
rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0
rpool/backups/192.168.1.20/rpool/data/vm-101-disk-0
```

Wygląda rozwlekle, ale jest jednoznaczne: po etykiecie od razu wiadomo, z
której maszyny pochodzi kopia, a oryginalna ścieżka jest zachowana w całości.
Dzięki temu jeden kolektor może przyjmować `rpool/data/vm-100-disk-0` z
dziesięciu różnych hostów bez żadnej kolizji nazw.

---

## 4a. Jak czytać wygenerowaną linię crona

Tych linii nikt nie pisze ręcznie — generuje je `gen-cron.sh` z pliku konfiguracyjnego. Ale
otwiera się je zwykle raz na pół roku, przy awarii, więc rozbiór jednego przykładu (to jest
prawdziwe wyjście dla wdrożenia z tej instrukcji, nie przepisane z pamięci):

```text
1 * * * * … snapget.sh -m "automated_hourly_" -i -K /root/.ssh/pairing/192.168.1.20_ed25519     -A -L pve-prod "zfsbackup-pve-backup@192.168.1.20:rpool/data/vm-100-disk-0"     "rpool/backups/192.168.1.20" …
```

| fragment | co znaczy | skąd się wziął |
|---|---|---|
| `1 * * * *` | co godzinę o :01 | `send_schedule` z szablonu |
| `-m "automated_hourly_"` | takim prefiksem nazywaj tworzone snapshoty; po nim rozpoznaje je retencja i monitoring | `prefix` |
| `-i` | przy nadrabianiu zaległości **przeskocz od razu do najnowszego stanu**, zamiast przechodzić przez wszystkie snapshoty po drodze. Szybciej i mniej danych, ale na kopii nie będzie stanów pośrednich | Twój `flags` |
| `-K …/192.168.1.20_ed25519` | loguj się na źródło **tym konkretnym kluczem** (tym z parowania). Robi to, co `ssh -i`, ale litera `i` była już zajęta — patrz wyżej | Twój `flags` |
| `-A` | **zmierz łącze i sam zdecyduj**, czy kompresja się opłaca. Wynik pamiętany tydzień: prędkość łącza per host, podatność danych per dataset | dokłada generator, domyślnie |
| `-L pve-prod` | ten transfer należy do **relacji `pve-prod`**. Dzięki temu `pause-client` i `disable-client` mogą go zatrzymać, zanim cokolwiek zrobi (patrz `docs/PAUZA-I-BLOKADA.md`) | `pair_label` |
| `"zfsbackup-…@192.168.1.20:rpool/data/vm-100-disk-0"` | **skąd bierzemy**: konto na źródle, jego adres i dataset. Ścieżka dosłowna — dokładnie to, co pokazuje tam `zfs list` | `src` |
| `"rpool/backups/192.168.1.20"` | **katalog bazowy, nie miejsce docelowe** | cel z `--target` + etykieta |

Ostatni wiersz to najczęstsze nieporozumienie. Dane **nie** wylądują w
`rpool/backups/192.168.1.20`, tylko o kilka poziomów głębiej — skrypt dokleja pod spodem całą
oryginalną ścieżkę ze źródła:

```text
rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0
```

czyli dokładnie to, co opisuje rozdział 4. To nie jest drobiazg redakcyjny: wpisanie tu od razu
pełnej ścieżki docelowej sprawia, że kopia ląduje o poziom za głęboko, **każdy przebieg robi
pełny transfer od zera**, a monitoring melduje, że wszystko gra — bo zagląda w to samo złe
miejsce. Ten błąd wystąpił naprawdę i był niewidoczny przez wiele dni.

Linia monitora dla tego samego datasetu wygląda tak:

```text
*/15 * * * * … check-snap-age.sh -L pve-prod "rpool/backups/192.168.1.20/rpool/data/vm-100-disk-0"     "automated_hourly" 90m 150m …
```

— czyli sprawdza **cel**, nie źródło, i zna tę samą etykietę relacji, więc podczas pauzy
odpowiada „to normalne, ta relacja stoi" zamiast budzić Cię co 15 minut.

---

## 5. Co się dzieje po wdrożeniu

Profil domyślny (jedyny zaimplementowany), wartości wprost z kodu:

| Element | Ustawienie |
|---|---|
| Snapshot + transfer | co godzinę, o **:01** |
| Prefiks snapshotów | `automated_hourly_` |
| Sprzątanie (GFS) | co godzinę, o **:21** |
| Retencja | **24** godzinowe, **7** dziennych, **4** tygodniowe, **12** miesięcznych |
| Alert (ostrzeżenie) | brak świeżej kopii przez **90 min** |
| Alert (krytyczny) | brak świeżej kopii przez **150 min** |

Retencja działa w modelu **GFS (dziadek-ojciec-syn)**: jedna seria godzinowych
snapshotów jest kubełkowana po czasie powstania. Nie robimy osobnych „dziennych"
i „miesięcznych" transferów — to byłyby dodatkowe kopie tych samych danych.

Alerty idą mailem. Domyślnie jeden zbiorczy raport dziennie na host; na czas
wdrażania warto przełączyć na natychmiastowe:

```bash
./deploy.sh --alerts=immediate
```

### Poczta na czystym Debianie (nie-Proxmox)

Na Proxmoksie to działa samo, bo instalator PVE konfiguruje postfixa. **Na
czystym Debianie zwykle nie ma żadnego MTA** — i wtedy backup chodzi
poprawnie, a każda awaria jest niema.

`deploy.sh` doinstaluje pakiet `mailutils`, ale to daje tylko *polecenie*
`mail`. Dostarczanie wymaga MTA, czyli osobnego pakietu. Dlatego skrypt
**wydaje osobny werdykt** o alertowaniu — w każdym trybie, także w
`--check-only`:

```
alert delivery: postfix present, no queued mail -- prerequisites OK; actual delivery UNVERIFIED in this run (--test-mail probes it)
ALERTING IS NOT WIRED UP: 'mail' exists but no MTA provides sendmail(8)
mail transport present (postfix) but 3 message(s) are STUCK IN THE QUEUE
```

Jeśli zobaczysz którykolwiek z dwóch ostatnich — alerty z tego hosta nie
działają. Minimalna naprawa:

```bash
apt-get install postfix
```

Przy pytaniu instalatora wybierz **„Local only"**, jeśli alerty mają iść do
lokalnego roota (domyślny adres tego pakietu), albo **„Internet Site"** /
**„Satellite system"**, jeśli mają wychodzić na zewnętrzny adres.

> **`deploy.sh` celowo NIE konfiguruje postfiksa.** To zmiana ogólnohostowa: gdy
> host ma już działającą pocztę (exim4, ustawiony relay, msmtp), nadpisanie
> `main.cf` zepsułoby cudzą konfigurację. Wybór smarthosta i poświadczeń SMTP
> to też decyzja per instalacja, a hasło musiałoby gdzieś zamieszkać. Ta sama
> zasada, dla której `--commit-scope` nie rusza cudzych grantów ZFS.

**Sprawdzenie po fakcie** — najprostszy dowód, że poczta faktycznie wychodzi:

```bash
./deploy.sh --check-only
mailq
```

Pusta kolejka po wysyłce znaczy, że MTA przyjął i wyprawił wiadomość.
Wiadomości zalegające w `mailq` znaczą, że alerty są produkowane i nie
docierają — to stan do naprawy, nie kosmetyka.

---

## 6. Wariant `sync` — lustro zamiast archiwum

Zamiast `--mode=backup` w kroku 2:

```bash
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=sync
```

Różnica jest jedna, ale zasadnicza: **ścieżki są odtwarzane jeden do jednego.**

```
źródło:  rpool/data/vm-100-disk-0
cel:     rpool/data/vm-100-disk-0     <- identyczna ścieżka, drugi host
```

Nie ma przedrostka z etykietą, nie ma `--target` (podanie go zostanie
odrzucone) — nie ma czego nazywać, skoro układ ma być identyczny.

**Kiedy tego użyć:** gdy budujesz maszynę zapasową gotową do przejęcia roli,
a nie archiwum. Po awarii `pve-prod` maszyny stoją na `pve-backup` pod tymi
samymi ścieżkami, których szuka konfiguracja Proxmoksa.

**Kiedy NIE:** `sync` **odmówi sparowania z hostem z tego samego klastra
PVE** — i słusznie. W jednym klastrze ta sama ścieżka to fizycznie ten sam
dataset, więc „źródło" i „cel" byłyby jednym obiektem, a synchronizacja
nadpisywałaby dane same sobą. Bramka stoi przy zgłoszeniu klienta, zanim
cokolwiek zostanie sparowane.

Wykluczenia i rekurencja działają dokładnie tak samo — plik zakresu jest ten
sam. Zmienia się wyłącznie mapowanie ścieżek.

---

## 7. Ograniczenia, o których musisz wiedzieć

Nazywamy je wprost, bo każde z nich zaskoczy Cię później, jeśli nie teraz.

### 7.1. Nowy dataset NIE zostanie objęty automatycznie

To najważniejszy punkt tej instrukcji.

`include_children = yes` rozwija się w **konkretną listę datasetów w momencie
wykonania `--commit-scope`** i ta lista zostaje zamrożona. Jeśli jutro
utworzysz `rpool/data/vm-102-disk-0`, **nie trafi ona do kopii** — nie ma
uprawnień i nie ma jej na liście.

Nie jest to błąd, tylko konsekwencja modelu: uprawnienia nadaje się świadomie,
per dataset. Ale znaczy to, że **każda nowa maszyna wymaga dwóch komend na
źródle**:

```bash
./deploy.sh --draft-scope=192.168.1.20   # tylko gdy plik zakresu nie istnieje
./deploy.sh --commit-scope=192.168.1.20  # po sprawdzeniu/uzupełnieniu pliku
```

a następnie na kolektorze:

```bash
./zfs-backup.sh activate-client prod01   # przegeneruje zadania
```

> **Wpisz to do swojej procedury tworzenia VM.** Maszyna, o której backupie
> wszyscy są przekonani, a której nikt nigdy nie skopiował, to najdroższy
> możliwy sposób odkrycia tego ograniczenia.

Automatyczne obejmowanie nowych datasetów jest w planach, ale wymaga zmiany
modelu uprawnień — nie ma go dziś.

### 7.2. Kopie są crash-consistent, nie application-consistent

W trybie pull **nie ma zamrażania systemu plików gościa** (quiesce) — maszyna
wirtualna żyje na zdalnym hoście. Snapshot odpowiada stanowi „jakby wyciągnięto
wtyczkę": systemy plików odtworzą się z dziennika, ale baza danych w trakcie
transakcji może wymagać własnego odzyskiwania.

Dla większości zastosowań to wystarcza. Dla baz z twardym wymogiem spójności
aplikacyjnej potrzebny jest backup po stronie aplikacji (dump) **obok** tego
mechanizmu.

### 7.3. Zmiana adresu źródła

Gdy `pve-prod` zmieni IP, **nie parujesz od nowa.** Nazwa `prod01` jest
niezależna od adresu:

```bash
./zfs-backup.sh set-endpoint prod01 --host=192.168.5.20
./zfs-backup.sh verify-endpoint prod01
./zfs-backup.sh activate-client prod01
```

Jeśli VPN zachowuje ten sam `host:port` — nie robisz nawet tego, wystarczy
`verify-endpoint`.

---

## 8. Podłączenie drugiego źródła

Ten sam kolektor obsługuje wiele źródeł. Powtarzasz kroki 2–10 z nową nazwą:

```bash
./zfs-backup.sh add-client prod02 --lan=192.168.1.21 --mode=backup
```

Każda relacja dostaje **własne konto na źródle, własny klucz i własny zakres
uprawnień**. Relacje o sobie nawzajem nie wiedzą i nie mogą się nawzajem
dotknąć — kompromitacja jednego źródła nie otwiera drogi do pozostałych.

---

## 9. Demontaż

Na kolektorze:

```bash
./zfs-backup.sh remove-client prod01
```

Usuwa zadania z crona, wpis klienta i sekcje konfiguracji. **Nie kasuje danych**
w `rpool/backups` — jeśli mają zniknąć, robisz to osobno i świadomie.

Na źródle (sprząta konto, klucz i uprawnienia ZFS tej relacji):

```bash
./deploy.sh --leave=192.168.1.20
```

---

## 10. Ściąga — cała procedura

```bash
# --- KOLEKTOR pve-backup ---
./zfs-backup.sh setup-server --target=rpool/backups --local-user=zfsbackup
./zfs-backup.sh add-client prod01 --lan=192.168.1.20 --mode=backup
#   -> przenieś wypisaną paczkę .tgz na pve-prod

# --- ŹRÓDŁO pve-prod ---
./deploy.sh --join=/root/prod01-package.tgz
./deploy.sh --draft-scope=192.168.1.20
vi /etc/zfs-snapshot-all/peers/192.168.1.20.scope      # wybór + wykluczenia
./deploy.sh --commit-scope=192.168.1.20

# --- KOLEKTOR pve-backup ---
./zfs-backup.sh seed prod01
./zfs-backup.sh verify-endpoint prod01
./zfs-backup.sh activate-client prod01
./zfs-backup.sh status
```

---

## 11. Gdy coś nie działa

| Objaw | Gdzie szukać |
|---|---|
| `seed` kończy się błędem uprawnień | czy `--commit-scope` na pewno wykonane? `zfs allow rpool/data` na źródle |
| `verify-endpoint` odmawia | adres/port; komunikat rozróżnia „nie mogę się połączyć" od problemu z danymi |
| brak wpisów w cronie | klient nie doszedł do `endpoint_verified` — sprawdź `status` |
| nowa VM nie jest kopiowana | to punkt 7.1, nie awaria |
| aktualizacje przestały przychodzić | `git -C /root/zfs-snapshot-all status` — brudne drzewo blokuje `--ff-only` |
| backup działa, ale nie ma alertów | `./deploy.sh --check-only` wyda werdykt o poczcie; potem `mailq`. Na nie-Proxmoksie zwykle brak MTA (rozdz. 5) |
| `mailq` pokazuje `alias database unavailable` | brak `/etc/aliases.db` — `newaliases` odbudowuje |

Stan całości zawsze pokaże:

```bash
./zfs-backup.sh status
./deploy.sh --check-only
```
