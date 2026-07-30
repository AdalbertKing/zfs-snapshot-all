# Dyskusja: uproszczony deploy, pve1 jako serwer backupu, `snapget.sh` jako rdzeń

- Autor uwag: ChatGPT
- Data: 2026-07-30
- Status: **DYSKUSJA — nie jest to jeszcze zatwierdzona architektura ani plan implementacji**
- Kontekst: dalsza dyskusja z właścicielem i Claude nad uproszczeniem wdrożenia dwóch serwerów

## 1. Punkt wyjścia

Pakiet jest technicznie rozbudowany, ale obecny model wdrożenia nadal wymaga od operatora rozumienia zbyt wielu szczegółów implementacyjnych: `--pair`, `--join`, `--role`, `--peer-datasets`, `--target`, `--as`, `--local-user`, `--draft-config`, rotacji kluczy, plików `known_hosts`, delegacji ZFS i osobnego generowania crona.

To jest poprawne jako warstwa administracyjna i ekspercka, ale nie jest doświadczeniem „po wyjęciu z pudełka działa”.

Docelowy użytkownik powinien rozumieć tylko dwa pojęcia:

- **serwer backupu** — pve1;
- **klient/źródło** — pve2.

Cała reszta powinna być domyślną implementacją ukrytą pod prostymi operacjami.

## 2. Zalecany model domyślny

Domyślnym modelem powinien być pull:

```text
pve1 -- snapget.sh --> pobiera dane z pve2
```

Konsekwencje:

- harmonogram działa na pve1;
- klucz prywatny znajduje się na pve1;
- retencja, alerty i polityka backupu należą do pve1;
- pve2 tylko udostępnia wskazane datasety;
- pve2 nie potrzebuje własnego crona backupowego;
- `snapget.sh` jest rdzeniem funkcjonalnym nowego prostego procesu;
- `snapsend.sh` zostaje jako tryb ekspercki, kompatybilnościowy i dla istniejących instalacji push.

Zasada produktowa:

> pve1 zarządza backupem. pve2 wyłącznie udostępnia dane.

## 3. Co powinno należeć do którego hosta

### pve1 — serwer backupu

pve1 powinien przechowywać i kontrolować:

- adres klienta;
- przypięty klucz hosta klienta;
- klucz prywatny relacji;
- konto zdalne;
- listę źródłowych datasetów;
- lokalny target;
- harmonogram;
- retencję;
- limity transferu;
- alerty;
- stan ostatniego testu i ostatniego backupu;
- lokalny plik konfiguracji klienta.

### pve2 — klient/źródło

pve2 powinien przechowywać tylko:

- konto dedykowane tej relacji;
- klucz publiczny pve1;
- delegacje `zfs allow` na wybranych datasetach;
- lokalny manifest: kto ma dostęp i do czego.

pve2 nie powinien decydować o harmonogramie, retencji, lokalnym targetcie pve1 ani instalować zadań backupowych.

## 4. Uwaga do obecnego Wariantu B

Nie rekomenduję, aby pve2 generował finalną konfigurację backupu albo decydował o lokalnych ścieżkach na pve1.

pve2 nie zna:

- układu puli backupowej na pve1;
- polityki retencji;
- harmonogramu;
- limitów łącza;
- dostępnego miejsca;
- lokalnych zasad alertowania;
- tego, czy klient ma być backupowany godzinowo, dziennie czy archiwalnie.

To są decyzje serwera backupu.

Po zaakceptowaniu klucza i delegacji przez pve2, pve1 może sam połączyć się z klientem, pobrać listę dostępnych datasetów, zbudować lokalną konfigurację, wykonać dry-run i zaproponować aktywację.

Paczka zwrotna może okazać się zbędna. Nadal trzeba niezależnie potwierdzić fingerprint hosta pve2; nie wolno pobierać fingerprintu tym samym nowym, jeszcze nieweryfikowanym kanałem i uznawać go za dowód tożsamości.

## 5. Proponowany przebieg użytkownika

Poniższe nazwy są robocze. Chodzi o model czynności, nie o ostateczną składnię.

### Krok 1 — przygotowanie pve1

```sh
zfs-backup setup-server
```

Program powinien:

- sprawdzić zależności;
- przygotować repo, monitoring i alerty;
- wykryć pule;
- zaproponować oczywisty magazyn backupowy;
- zapisać lokalny target, np. `hdd/backups`;
- ustawić profil domyślny.

`deploy.sh` może pozostać backendem, ale nie powinien być głównym interfejsem użytkownika końcowego.

### Krok 2 — dodanie klienta na pve1

```sh
zfs-backup add-client pve2
```

Program powinien automatycznie przyjąć:

```text
role         = pull
remote user  = delegowane konto per klient
local runner = konto usługi albo root, zgodnie z przyjętą polityką
host key     = przypięty po ręcznym potwierdzeniu fingerprintu
engine       = snapget.sh
```

Powinien wygenerować dedykowany klucz i jedną małą paczkę inicjalizacyjną do przeniesienia na pve2.

Nie powinien pytać o flagi, które mają jeden bezpieczny i oczywisty domyślny wariant.

### Krok 3 — akceptacja na pve2

```sh
zfs-backup enroll /root/pve1-enroll.tgz
```

Program powinien:

- pokazać, który serwer prosi o dostęp;
- wykryć sensowne źródłowe datasety;
- pozwolić zaznaczyć dane do udostępnienia;
- utworzyć dedykowane konto;
- zainstalować klucz publiczny;
- nadać właściwe delegacje `zfs allow`;
- zapisać manifest;
- pokazać fingerprint hosta pve2 do porównania na pve1.

Przykładowy ekran:

```text
Serwer backupu: pve1
Konto: zfsbackup-pve1

Wykryte źródła:
[x] rpool/data
[x] rpool/ROOT/pve-1
[ ] hdd/temp

Aktywować dostęp? [T/n]
```

pve2 nie instaluje crona i nie uruchamia backupu.

### Krok 4 — aktywacja na pve1

```sh
zfs-backup activate-client pve2
```

Program powinien:

1. zeskanować klucz hosta pve2;
2. porównać fingerprint z wartością odczytaną niezależnie na pve2;
3. przypiąć klucz hosta;
4. sprawdzić połączenie;
5. pobrać listę dostępnych datasetów;
6. zbudować kompletną lokalną konfigurację;
7. wykonać `snapget.sh -n`;
8. pokazać jedno czytelne podsumowanie;
9. po potwierdzeniu zainstalować zadanie.

Przykładowe podsumowanie:

```text
Klient:        pve2
Źródła:        rpool/data, rpool/ROOT/pve-1
Cel:           hdd/backups/pve2
Tryb:          pull
Częstotliwość: co godzinę
Retencja:      standard
Kompresja:     automatyczna
Montowanie:    wyłączone
Test:          poprawny

Aktywować backup? [T/n]
```

To nie jest bezmyślna automatyzacja. Program podejmuje decyzje domyślne, pokazuje wynik i wymaga jednego potwierdzenia.

## 6. Dlaczego `snapget.sh` jest dobrym rdzeniem

`snapsend.sh` i `snapget.sh` mają wiele opcji eksperckich, ale `snapget.sh` ma już sensowne zachowanie domyślne dla appliance backupowego:

- zdalny transfer automatycznie korzysta z kompresji zstd, chyba że użytkownik ją wyłączy;
- odbierane datasety domyślnie nie są montowane;
- lokalny target może być budowany przez `LOCAL_BASE`;
- `-R` może rozbić drzewo źródłowe na niezależne zadania per dataset;
- pve1 ma pełną kontrolę nad odbiorem, targetem i harmonogramem;
- źródłowy pve2 nie musi otwierać się jako cel przychodzącego strumienia `zfs recv`.

Robocza komenda generowana wewnętrznie mogłaby wyglądać tak:

```sh
snapget.sh -R \
  -K /etc/zfs-snapshot-all/clients/pve2/id_ed25519 \
  -k /etc/zfs-snapshot-all/clients/pve2/known_hosts \
  zfsbackup-pve1@pve2:rpool/data \
  hdd/backups/pve2
```

Użytkownik końcowy nie powinien jej jednak ręcznie składać.

## 7. Jeden lokalny plik prawdy na pve1

Propozycja:

```text
/etc/zfs-snapshot-all/clients/pve2.conf
```

Plik powinien zawierać co najmniej:

- identyfikator klienta;
- host/IP i port;
- zdalne konto;
- plik klucza prywatnego;
- plik przypiętego host key;
- źródłowe datasety;
- lokalny target;
- profil częstotliwości;
- profil retencji;
- wykluczenia;
- stan aktywacji;
- datę i wynik ostatniego testu.

To powinno być źródłem dla statusu, testu, instalacji crona, zmiany polityki i usuwania klienta.

Na pve2 pozostaje osobny manifest autoryzacji. Nie próbujemy mieć jednego magicznego pliku synchronizowanego w obie strony.

## 8. Interfejs produktowy zamiast interfejsu skryptowego

Proponowany interfejs użytkownika:

```sh
zfs-backup setup-server
zfs-backup add-client pve2
zfs-backup activate-client pve2
zfs-backup status
zfs-backup test pve2
zfs-backup remove-client pve2
```

Może to być nowy wrapper, który wewnętrznie używa istniejących:

- `deploy.sh`;
- `snapget.sh`;
- `gen-cron.sh`;
- mechanizmu pair/join;
- manifestów i testów.

Na tym etapie nie ma potrzeby przepisywać działającego rdzenia. Najpierw należy zbudować prostą warstwę orkiestracji i sensowne profile domyślne.

## 9. Domyślne profile zamiast wielu pytań

Dobry interfejs nie pyta użytkownika o każdą flagę. Powinien mieć kilka nazwanych profili, np.:

- `standard` — rozsądny harmonogram i retencja dla większości serwerów;
- `frequent` — częstsze snapshoty dla aktywnych VM;
- `archive` — rzadszy backup, dłuższa retencja;
- `custom` — przejście do obecnego zaawansowanego INI.

Użytkownik wybiera cel operacyjny, nie zestaw flag ZFS.

## 10. Co zachować jako tryb ekspercki

Nie należy usuwać istniejących możliwości. Powinny pozostać dostępne dla administratora:

- push przez `snapsend.sh`;
- `--as=root` dla istniejących, w pełni zaufanych klastrów;
- niestandardowe porty i `ProxyJump`;
- własne flagi send/recv;
- zaawansowane wykluczenia;
- osobne joby i identyfikatory;
- ręczne INI `gen-cron.sh`;
- ręczna rotacja i diagnostyka.

Różnica polega na tym, że tryb ekspercki nie może być jedyną drogą do uruchomienia zwykłego backupu.

## 11. Ważne zabezpieczenia, których uproszczenie nie może usunąć

Uproszczenie UX nie może cofnąć dotychczasowych zabezpieczeń:

- dedykowany klucz per relacja;
- dedykowane konto per klient;
- delegacje ZFS tylko na wybrane datasety;
- przypięcie host key po niezależnym potwierdzeniu fingerprintu;
- odrzucanie błędnej lub publicznie rozwiązującej się nazwy bez jawnego opt-in;
- bezpieczny parser paczki enroll/join;
- dry-run przed instalacją zadania;
- brak automatycznego kasowania danych przy `remove-client`;
- brak odbierania cudzych lub dziedziczonych grantów bez ostrzeżenia;
- idempotencja i możliwość ponownego uruchomienia procesu.

Łatwość obsługi ma wynikać z dobrych domyślnych decyzji i orkiestracji, nie z obniżenia poziomu bezpieczeństwa.

## 12. Decyzje do dalszej dyskusji

1. Czy nowy prosty proces całkowicie rezygnuje z paczki zwrotnej, a pve1 po `enroll` sam odkrywa dozwolone datasety?
2. Czy lokalne zadania na pve1 mają domyślnie działać jako root, czy przez jedno konto usługi?
3. Jak wybrać domyślny target, gdy pve1 ma kilka pul?
4. Jaki ma być profil `standard`: harmonogram, retencja i próg alertów?
5. Czy po aktywacji pierwszy realny backup uruchamia się natychmiast, czy dopiero z crona?
6. Czy interfejs ma być wyłącznie CLI, czy od początku projektować format stanu pod późniejsze GUI?
7. Czy wrapper ma nazywać się `zfs-backup`, czy inaczej?
8. Jak zachować kompatybilność z istniejącymi ręcznymi configami i obecnymi hostami push?
9. Czy `add-client` i `activate-client` mają być osobnymi komendami, czy jedną komendą z przerwą na wykonanie kroku na pve2?
10. Jak formalnie rozdzielić „serwer backupu”, „klienta” i „peer” w nazewnictwie kodu oraz manifestów?

## 13. Moja rekomendacja robocza

Na dalszą dyskusję proponuję przyjąć jako kierunek bazowy:

> pve1 jest appliance'em backupowym i jedynym miejscem zarządzania. pve2 jest klientem udostępniającym dane. Domyślnym silnikiem jest `snapget.sh`. Obecne mechanizmy pair/join, delegacji, host-key pinning i `gen-cron.sh` pozostają backendem. Nowa praca powinna skupić się najpierw na warstwie orkiestracji, prostych profilach i jednym lokalnym pliku klienta, a nie na przepisywaniu działającego silnika replikacji.

Dokument jest wkładem do dyskusji. Nie zatwierdza nazw komend, formatu pliku klienta, profilu `standard` ani rezygnacji z paczki zwrotnej.