# Uzgodnione stanowisko: uproszczony deploy oparty na `snapget.sh`

- Uczestnicy stanowiska: właściciel projektu, ChatGPT (reviewer), Claude (implementer)
- Data: 2026-07-30
- Status: **UZGODNIONY KIERUNEK ARCHITEKTONICZNY DO DALSZEJ DYSKUSJI I PROJEKTOWANIA**
- Dokumenty wejściowe:
  - `DEPLOY-UX-SNAPGET-FIRST.md`
  - `DEPLOY-UX-LAN-SEED-TO-VPN.md`
  - `DEPLOY-UX-FINGERPRINT-TRUST.md`
  - `DEPLOY-UX-IMPLEMENTER-NOTES.md`

Dokument zamyka różnice pomiędzy uwagami reviewera i implementera na poziomie kierunku. Nie zatwierdza jeszcze finalnych nazw komend, formatu plików konfiguracyjnych ani profilu retencji `standard`.

## 1. Model produktu

Domyślny produkt ma być rozumiany przez użytkownika jako:

- **pve1 — serwer backupu / appliance zarządzający**;
- **pve2 — klient / źródło danych**;
- **`snapget.sh` — domyślny silnik pull**.

```text
pve1 -- snapget.sh --> pobiera snapshoty z pve2
```

pve1 jest jedynym miejscem zarządzania harmonogramem, retencją, targetem, alertami i polityką transferu. pve2 jedynie udostępnia wybrane datasety przez dedykowane konto i delegacje ZFS.

`snapget.sh`, `deploy.sh`, `gen-cron.sh`, obecne pair/join, manifesty i testy pozostają backendem. Nie przepisujemy działającego silnika replikacji.

## 2. Nowa warstwa UX jako osobny program

Nowy prosty interfejs powstaje jako **osobny plik/program orkiestrujący**, roboczo `zfs-backup`.

Nie rozbudowujemy publicznego interfejsu `deploy.sh` o kolejne tryby produktowe. `deploy.sh` pozostaje backendem przygotowania i audytu hosta oraz kontrolera aktualizacji/rollbacku.

Powody:

- minimalizacja ryzyka regresji w świeżo zaakceptowanym `deploy.sh`;
- oddzielenie operacji użytkownika od technicznych faz instalacyjnych;
- możliwość budowy prostego workflow bez usuwania trybu eksperckiego;
- łatwiejsze testowanie stanu klienta i etapów konfiguracji.

Nowy plik od pierwszego commita musi być wpisany do `test/deps.conf` i posiadać własne testy.

## 3. Trwała relacja, zmienny transport

Relacja backupowa nie jest adresem IP.

Należy rozdzielić:

1. stałą tożsamość klienta/relacji;
2. tożsamość kryptograficzną;
3. zmienny endpoint transportowy.

Ta sama relacja może używać kolejno:

- endpointu LAN podczas inicjalnego seeda;
- endpointu VPN po wyniesieniu pve1 poza firmę.

Zmiana endpointu nie może powodować:

- ponownego parowania;
- nowego klucza relacji;
- nowego targetu;
- nowego identyfikatora joba;
- nowych bookmarków lub plików stanu;
- ponownego pełnego transferu.

## 4. Fingerprint i `HostKeyAlias`

Jeden fingerprint klucza hosta pve2, poprawnie potwierdzony niezależnym kanałem podczas inicjalizacji, jest wystarczającym potwierdzeniem tożsamości pve2 dla późniejszych endpointów LAN i VPN.

Zmiana IP, DNS, portu albo trasy nie wymaga nowego zaufania, jeżeli pve2 przedstawia ten sam klucz hosta.

Warstwa orkiestracji ma automatycznie generować:

```text
-O HostKeyAlias=zfs-client-<client_id>
-k /etc/zfs-snapshot-all/clients/<client_id>/known_hosts
```

Obecny silnik już obsługuje `-O HostKeyAlias=...`, a `gen-cron.sh` przepuszcza tę opcję. Potrzebna jest orkiestracja i model danych, nie zmiana protokołu SSH w `snapget.sh`.

Zmiana fingerprintu ma zatrzymać operację i wymagać osobnej, świadomej procedury zatwierdzenia.

## 5. LAN seed, potem VPN incremental

Podstawowy scenariusz wdrożenia:

1. pve1 zostaje podłączony do LAN firmy obok pve2;
2. pve1 tworzy relację i paczkę enroll;
3. pve2 akceptuje relację i udostępnia wybrane datasety;
4. pve1 potwierdza fingerprint pve2;
5. pve1 wykonuje pełny seed przez LAN;
6. pve1 wykonuje finalny krótki catch-up przed odłączeniem;
7. pve1 zostaje wyniesiony poza firmę;
8. endpoint relacji zostaje jawnie zmieniony na VPN;
9. wykonywany jest test połączenia i test incremental;
10. dopiero po sukcesie aktywowany jest harmonogram produkcyjny.

Minimalny test akceptacyjny end-to-end:

```text
full LAN -> incremental LAN -> zmiana endpointu -> incremental VPN
```

bez `-f`, bez nowego targetu i bez nowej tożsamości joba.

Obecny `job_state_key()` nie zawiera `remote_host`, więc kierunek jest już zgodny z wymaganiem. Potrzebny jest test całego przejścia, nie zmiana tego klucza.

## 6. Jawny endpoint zamiast automatycznego failoveru

Domyślnie relacja ma jeden jawnie aktywny endpoint, np. `lan` albo `vpn`.

Program może wykrywać dostępność innych wcześniej skonfigurowanych i zaufanych endpointów oraz proponować przełączenie, ale nie powinien automatycznie wybierać trasy dla dużego transferu.

Ma to zapobiec przypadkowemu wykonaniu pełnego seeda przez WAN albo połączeniu przez błędny DNS.

Nowy endpoint musi przedstawić ten sam przypięty klucz hosta poprzez stały `HostKeyAlias`.

## 7. Wariant B zostaje historycznie, ale jest zastąpiony

`PAIRING-DESIGN.md` Wariant B — model, w którym pve2 buduje finalną konfigurację dla pve1 — uznajemy za **superseded by this discussion**.

Nie usuwamy opisu, ponieważ dokumentuje rozważany wariant i przyczynę jego odrzucenia.

Powód decyzji:

- pve2 nie zna targetu, harmonogramu, retencji, limitów, miejsca i polityki alertów pve1;
- finalna konfiguracja backupu musi powstawać na pve1;
- pve2 ma tylko zatwierdzić tożsamość relacji oraz zakres udostępnionych danych.

## 8. Dwa oddzielne punkty procesu

Utrzymujemy dwa oddzielne kroki użytkownika:

1. utworzenie relacji i paczki dla klienta;
2. dokończenie konfiguracji na pve1 po wykonaniu enroll na pve2.

Roboczo:

```sh
zfs-backup add-client pve2
zfs-backup activate-client pve2
```

Rozdzielenie jest naturalne, ponieważ pomiędzy nimi istnieje rzeczywisty ręczny krok na drugim hoście. Jedna komenda nie może przejść przez ten punkt bez ustanowionego kanału.

Nazwy pozostają robocze.

## 9. Konfiguracja powstaje na pve1

Po enroll pve1:

- łączy się z pve2;
- pobiera listę dostępnych datasetów;
- buduje pełną lokalną konfigurację;
- wykonuje `snapget.sh -n`;
- pokazuje użytkownikowi czytelne podsumowanie;
- wymaga jednego potwierdzenia.

Może wykorzystać istniejącą logikę `--draft-config`, ale użytkownik nie powinien ręcznie przenosić `.suggested`, składać flag `snapget.sh` ani osobno uruchamiać `gen-cron.sh`.

## 10. Cron dopiero po teście VPN

W tym punkcie uzgodnione stanowisko odchodzi od propozycji implementera dotyczącej instalacji crona już podczas seeda z osobnym holdem.

**Nie instalujemy aktywnej ani „wstrzymanej” linii cron podczas seeda.**

Podczas fazy LAN:

- konfiguracja klienta może być kompletna;
- pełny seed i finalny catch-up są uruchamiane jawnie przez orkiestrator;
- relacja ma stan `seed` / `seed_complete`, ale nie ma produkcyjnego harmonogramu.

Cron zostaje zainstalowany dopiero wtedy, gdy:

1. seed jest zakończony;
2. aktywny endpoint został zmieniony na VPN;
3. VPN/SSH/host key działają;
4. dry-run potwierdzi możliwość incrementalu;
5. użytkownik zatwierdzi aktywację.

Uzasadnienie:

- jest to prostsze niż budowa nowego mechanizmu holda dla jobów backupowych;
- stan fail-closed jest oczywisty: brak wpisu cron oznacza brak automatycznego transferu;
- nie ma ryzyka przypadkowego startu pełnego joba przez WAN;
- nie mieszamy holda aktualizatora `update-control.sh` ze stanem aktywacji klienta backupowego.

Jeżeli później pojawi się potrzeba czasowego wstrzymywania aktywnych klientów, należy zaprojektować osobny, jawny mechanizm `pause/resume-client`, a nie reużywać semantyki aktualizatora.

## 11. Delegacje ZFS i odziedziczone uprawnienia

Przed nadaniem delegacji podczas enroll program musi sprawdzić efektywne, również odziedziczone uprawnienia konta.

Ma raportować osobno:

- grant nadany bezpośrednio przez tę relację;
- grant już istniejący na datasecie;
- szerszy grant odziedziczony z przodka.

Nie może sugerować izolacji per dataset, jeśli konto już ma szerszy dostęp z innego grantu.

Automatyczne usuwanie obcych lub odziedziczonych grantów pozostaje zabronione.

## 12. Pusty wybór datasetów

Jeżeli użytkownik nie wybierze żadnego datasetu, orkiestrator kończy operację komunikatem:

```text
Nie wybrano żadnych danych. Relacja nie została aktywowana i nie zainstalowano zadania.
```

Nie przekazuje pustej listy ani zestawu wykluczeń do `snapget.sh` i nie instaluje pustego joba.

## 13. Tryb ekspercki pozostaje

Obecne funkcje pozostają dostępne:

- push przez `snapsend.sh`;
- ręczny `deploy.sh --pair/--join`;
- `--as=root` dla pełnego zaufania;
- ręczne INI `gen-cron.sh`;
- niestandardowe SSH, `ProxyJump`, send/recv flags;
- ręczna diagnostyka i rotacja.

Nowa warstwa jest domyślną prostą drogą, a nie usunięciem możliwości administracyjnych.

## 14. Stan dyskusji po uzgodnieniu

Uzgodnione:

- kierunek snapget-first;
- pve1 jako jedyne centrum zarządzania;
- osobny wrapper/orchestrator;
- stała relacja niezależna od IP;
- jeden potwierdzony fingerprint dla LAN/VPN;
- `HostKeyAlias` jako standard nowego procesu;
- jawne przełączenie LAN -> VPN;
- Wariant B zastąpiony przez ten kierunek;
- konfiguracja generowana na pve1;
- dwa punkty procesu add/activate;
- cron dopiero po pozytywnym teście VPN;
- kontrola odziedziczonych `zfs allow`;
- brak joba przy pustym wyborze.

Nadal do rozstrzygnięcia:

- finalna nazwa programu i komend;
- format oraz lokalizacja pliku klienta;
- dokładna maszyna stanów relacji;
- domyślne profile harmonogramu i retencji;
- sposób wyboru targetu przy kilku pulach;
- domyślne konto lokalne uruchamiające joby;
- procedura zmiany fingerprintu po legalnej reinstalacji pve2;
- szczegółowy UX seeda, catch-up i pierwszej aktywacji.

Ten dokument jest punktem bazowym dla kolejnej rundy dyskusji i przyszłego planu implementacji.