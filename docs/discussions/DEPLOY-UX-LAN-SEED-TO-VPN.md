# Dyskusja: inicjalny seed w LAN, późniejsza praca pve1 poza firmą przez VPN

- Autor uwag: ChatGPT
- Data: 2026-07-30
- Status: **DYSKUSJA — uzupełnienie `DEPLOY-UX-SNAPGET-FIRST.md`, nie zatwierdzona architektura**
- Scenariusz: pve1 jest przygotowywany obok pve2 w firmowej sieci LAN, wykonuje pierwszy pełny backup z dużą prędkością, a następnie jest wynoszony poza firmę i kontynuuje backupy przez VPN/WAN, potencjalnie z innym adresem IP.

## 1. Najważniejsza zasada

Relacja backupowa nie może być utożsamiana z adresem IP ani aktualną trasą sieciową.

Należy rozdzielić trzy pojęcia:

1. **tożsamość klienta** — stałe `client_id`, np. `pve2` albo wewnętrzny UUID relacji;
2. **tożsamość kryptograficzna** — dedykowany klucz relacji oraz przypięty klucz hosta SSH pve2;
3. **endpoint transportowy** — aktualny adres/hostname i port, przez który pve1 dociera do pve2.

LAN i VPN są dwoma transportami tej samej relacji. Zmiana transportu nie może oznaczać ponownego parowania, nowego targetu, nowego joba ani ponownego pełnego transferu.

## 2. Model docelowy

```text
FAZA A — seed lokalny

pve1 (LAN) ---- szybki snapget/full ----> pve2 (LAN)

FAZA B — praca operacyjna

pve1 (poza firmą) ---- VPN/WAN + snapget/incremental ----> pve2 (firma)
```

`pve1` nadal inicjuje połączenie i pobiera dane. Zmienia się wyłącznie ścieżka sieciowa.

Własny adres IP pve1 zwykle nie ma znaczenia dla `snapget.sh`, ponieważ to pve1 otwiera połączenie wychodzące. Ma znaczenie jedynie wtedy, gdy firewall pve2 albo wpis `authorized_keys` ogranicza dostęp według adresu źródłowego. Takiego trwałego związania z adresem LAN nie należy stosować domyślnie, bo po wyniesieniu pve1 z firmy natychmiast zerwałoby ono działającą relację.

## 3. Stała relacja, zmienne endpointy

Lokalny plik klienta na pve1 powinien przechowywać stałą relację oraz jeden lub więcej endpointów, np. koncepcyjnie:

```ini
client_id = pve2
relation_id = 7f4d...        # stały identyfikator, niezależny od nazwy i IP
source_datasets = rpool/data rpool/ROOT/pve-1
target = hdd/backups/pve2
remote_user = zfsbackup-pve1
identity_file = /etc/zfs-snapshot-all/clients/pve2/id_ed25519
host_key_alias = zfs-client-pve2
active_endpoint = vpn

[endpoint.lan]
host = 192.168.1.20
port = 22
purpose = bootstrap

[endpoint.vpn]
host = 10.8.0.20
port = 22
purpose = operational
requires_vpn = true
```

To jest przykład modelu danych, nie propozycja finalnej gramatyki.

Adres jest właściwością endpointu, nie klienta. Pole `client_id` pozostaje stałe nawet wtedy, gdy zmienią się:

- IP pve1;
- IP pve2 widziane przez pve1;
- podsieć VPN;
- DNS;
- port SSH;
- lokalizacja fizyczna pve1.

## 4. Host key nie może być przypięty do jednego IP

Klucz hosta SSH identyfikuje pve2, a nie jego interfejs LAN albo VPN. Ten sam sshd zwykle przedstawia ten sam host key na wszystkich interfejsach.

Problem praktyczny: zwykły plik `known_hosts` wiąże klucz z tekstem hosta lub IP. Po zmianie `192.168.1.20` na `10.8.0.20` OpenSSH traktuje to jako nową nazwę, mimo że serwer i klucz są te same.

Proponowane rozwiązanie dla uproszczonej warstwy orkiestracji:

- użyć stałego `HostKeyAlias`, np. `zfs-client-pve2`;
- w dedykowanym pliku `known_hosts` zapisać przypięty klucz pod tym aliasem;
- łączyć się z aktualnym adresem, ale weryfikować zawsze względem stałego aliasu;
- przy zmianie endpointu wymagać tego samego już zatwierdzonego fingerprintu, a nie wykonywać nowego `accept-new`.

Koncepcyjnie generowana komenda SSH/snapget zawierałaby:

```text
-O HostKeyAlias=zfs-client-pve2
-k /etc/zfs-snapshot-all/clients/pve2/known_hosts
```

Dzięki temu zmiana LAN → VPN nie wymaga ponownego ustanawiania zaufania, jeżeli pve2 nadal przedstawia ten sam klucz hosta.

Jeżeli fingerprint się zmieni, operacja ma zostać zatrzymana. Zmiana adresu jest normalna; zmiana tożsamości kryptograficznej nie jest normalna i wymaga osobnego, świadomego zatwierdzenia.

## 5. Pierwszy pełny backup jako osobna faza „seed”

Pierwszy transfer może obejmować setki gigabajtów lub terabajty. Wykonywanie go przez WAN byłoby powolne i kosztowne, dlatego produkt powinien jawnie rozumieć fazę seed.

Proponowany przebieg:

1. pve1 zostaje podłączony do tego samego LAN co pve2;
2. następuje enroll/parowanie i przypięcie host key pve2;
3. pve1 wykonuje pierwszy pełny `snapget.sh` po LAN;
4. wykonywany jest test integralności i obecności wspólnych snapshotów/bookmarków;
5. tuż przed odłączeniem pve1 wykonywany jest ostatni krótki incremental/catch-up;
6. relacja zostaje oznaczona jako `seed_complete`;
7. pve1 zostaje przeniesiony poza firmę;
8. aktywny endpoint zostaje przełączony z `lan` na `vpn`;
9. wykonywany jest test VPN oraz dry-run incremental;
10. cron zostaje włączony albo wznowiony bez tworzenia nowej relacji.

Roboczy interfejs użytkownika mógłby wyglądać tak:

```sh
zfs-backup add-client pve2
zfs-backup seed pve2
zfs-backup set-endpoint pve2 --vpn 10.8.0.20
zfs-backup test pve2
zfs-backup activate-client pve2
```

Nazwy są wyłącznie materiałem do dyskusji. Istotne jest rozdzielenie seeda od późniejszego transportu.

## 6. Przełączenie endpointu nie może zmieniać tożsamości joba

Po zmianie adresu system ma kontynuować ten sam backup incremental. Muszą pozostać niezmienione:

- `client_id` / `relation_id`;
- źródłowy dataset, np. `rpool/data`;
- lokalny target, np. `hdd/backups/pve2/rpool/data`;
- identyfikator joba;
- nazwa bookmarku;
- klucz locka;
- pliki stanu resume/in-flight;
- historia snapshotów na obu końcach.

Obecny `snapget.sh` zapisuje stan in-flight poprzez parę `tgt_dataset` + `src_dataset`, bez dodawania `remote_host` do tego wywołania. To jest właściwy kierunek: endpoint nie powinien być częścią logicznej tożsamości transferu. Mimo to przejście LAN → VPN wymaga osobnego testu regresyjnego obejmującego locki, bookmarki i resume, żeby żadna inna warstwa nie zaczęła traktować zmiany hosta jako nowego joba.

Minimalny test akceptacyjny:

1. pełny seed przez endpoint LAN;
2. co najmniej jeden incremental przez LAN;
3. zmiana wyłącznie endpointu na VPN;
4. incremental przez VPN bez `-f` i bez ponownego pełnego send;
5. potwierdzenie użycia istniejącej wspólnej bazy/bookmarku;
6. brak nowych równoległych plików lock/state dla tej samej relacji.

## 7. Endpoint LAN i VPN: automatyczny wybór czy jawne przełączenie

Możliwe są dwa modele.

### Model A — jawny aktywny endpoint

Administrator wykonuje `set-endpoint` albo wybiera profil `lan`/`vpn`. Cron używa wyłącznie endpointu oznaczonego jako aktywny.

Zalety:

- zachowanie jest całkowicie przewidywalne;
- po wyniesieniu pve1 nie próbuje ono przypadkiem starego LAN/DNS;
- łatwa diagnostyka.

### Model B — lista zaufanych endpointów i failover

pve1 próbuje po kolei wyłącznie wcześniej skonfigurowanych endpointów, np. VPN, potem LAN. Każdy z nich musi przedstawić ten sam przypięty host key przez `HostKeyAlias`.

Zalety:

- mniej ręcznej obsługi;
- ten sam config działa podczas seeda i po przeniesieniu.

Ryzyko:

- automatyczny fallback może utrudnić rozpoznanie, którędy faktycznie idzie transfer;
- błędny DNS lub routing może skierować duży transfer inną drogą niż zakładana;
- szczególnie niepożądane byłoby przypadkowe wykonanie pełnego seeda przez wolny WAN.

Moja rekomendacja robocza: **jawny aktywny endpoint**, ale komenda `test` może wykryć dostępne, zaufane endpointy i zaproponować przełączenie. Nie należy automatycznie ufać nowemu adresowi ani samoczynnie dopisywać go przez TOFU.

## 8. VPN jako warunek operacyjny

Konfiguracja klienta powinna móc oznaczyć endpoint jako `requires_vpn=true` oraz określić warunek gotowości, np.:

- istnienie interfejsu `tun0`, `wg0` lub innego wskazanego interfejsu;
- obecność trasy do podsieci klienta;
- możliwość połączenia TCP z właściwym portem;
- poprawną weryfikację host key.

Przed backupem program powinien rozróżnić:

- VPN nieaktywny;
- brak trasy;
- port SSH nieosiągalny;
- host key mismatch;
- błąd autoryzacji;
- błąd ZFS.

Brak VPN ma zakończyć job czytelnym statusem i alertem. Nie może powodować:

- przejścia na `accept-new`;
- próby przypadkowego publicznego DNS;
- ponownego parowania;
- pełnego transferu;
- zmiany targetu.

## 9. Co z adresem źródłowym pve1

Ponieważ pve1 inicjuje pull, pve2 widzi połączenie z:

- lokalnego IP pve1 podczas seeda w LAN;
- adresu VPN pve1 po przeniesieniu;
- ewentualnie adresu bramy/NAT, zależnie od architektury VPN.

Dlatego domyślna relacja nie powinna ograniczać klucza w `authorized_keys` do jednego adresu LAN przez `from="192.168..."`.

Jeżeli ograniczenie źródłowe ma być dostępne w trybie hardened, powinno przyjmować listę zaufanych sieci lub endpointów, np. LAN + podsieć VPN, oraz posiadać kontrolowaną procedurę migracji. Nie może być ukrytym domyślnym założeniem.

Firewall może nadal ograniczać SSH do sieci LAN/VPN. To jest właściwsza warstwa kontroli trasy niż trwałe związanie klucza relacji z jednym adresem pve1.

## 10. Zachowanie po relokacji pve1

Po uruchomieniu pve1 poza firmą oczekiwany ekran powinien mówić wprost:

```text
Klient:                  pve2
Relacja:                 istniejąca, seed zakończony
Ostatnia wspólna baza:   snapshot/bookmark znaleziony
Endpoint aktywny:        VPN 10.8.0.20:22
VPN:                     aktywny
Host key:                zgodny z przypiętym fingerprintem
Test incremental:        poprawny
Pełny transfer:          NIE jest wymagany
Najbliższy backup:       02:00
```

Jeżeli VPN nie działa:

```text
Klient:                  pve2
Endpoint aktywny:        VPN 10.8.0.20:22
Stan:                    VPN/trasa niedostępna
Relacja i dane:          bez zmian
Ponowne parowanie:       NIE jest wymagane
Pełny transfer:          NIE jest wymagany
```

To jest ważne z perspektywy użytkownika: brak łączności nie może wyglądać jak utrata konfiguracji albo konieczność zaczynania od zera.

## 11. Konsekwencje dla uproszczonego UX

Proces „po wyjęciu z pudełka” powinien rozumieć dwie fazy:

- **przygotuj i zasiej lokalnie**;
- **przenieś i uruchom zdalnie**.

Nie powinien natomiast wystawiać użytkownikowi technicznych pytań typu:

- czy wygenerować nowy klucz;
- czy zmienić nazwę joba;
- czy utworzyć nowy target;
- czy wykonać full;
- czy ponownie zaufać host key.

Odpowiedź na wszystkie te pytania przy zwykłej zmianie LAN → VPN brzmi: **nie**. Zmienia się wyłącznie endpoint transportowy.

## 12. Decyzje do dalszej dyskusji

1. Czy utrzymujemy dwa jawne profile endpointu (`lan`, `vpn`), czy jeden aktywny endpoint z historią poprzednich?
2. Czy `HostKeyAlias` ma być obowiązkowym elementem nowego prostego procesu?
3. Czy przełączenie endpointu ma wymagać jednej jawnej komendy, czy program może zaproponować je po wykryciu niedostępności LAN?
4. Czy cron ma być instalowany już podczas seeda, ale w stanie wstrzymanym, czy dopiero po teście VPN?
5. Czy po LAN wykonujemy jeden pełny transfer i ręczny finalny catch-up, czy program ma prowadzić użytkownika przez oba kroki?
6. Jak oznaczyć `seed_complete` i jak potwierdzić, że następny transfer przez VPN będzie incremental?
7. Czy pve1 ma utrzymywać endpoint awaryjny LAN po wyniesieniu, czy usuwać go z aktywnej konfiguracji?
8. Czy hardened mode ma wspierać ograniczenie adresów źródłowych i jak bezpiecznie migrować je z LAN na VPN?
9. Jak ma wyglądać konfiguracja, gdy VPN zapewnia stały DNS klienta i w praktyce ten sam hostname działa lokalnie oraz zdalnie?
10. Czy warstwa orkiestracji ma samodzielnie kontrolować stan VPN, czy jedynie diagnozować wynik połączenia SSH?

## 13. Rekomendacja robocza

Na dalszą dyskusję proponuję przyjąć:

> pve1 i pve2 tworzą jedną trwałą relację backupową o stałej tożsamości kryptograficznej i stałym mapowaniu datasetów. Pierwszy pełny seed odbywa się po LAN. Po przeniesieniu pve1 zmieniany jest wyłącznie jawny endpoint z LAN na VPN. Ten sam przypięty host key, klucz relacji, target, job, bookmarki i historia snapshotów są zachowane, dzięki czemu kolejne transfery pozostają incremental. Adres IP jest właściwością transportu, nie tożsamości klienta.

Dokument nie zatwierdza finalnej składni komend ani formatu pliku klienta. Uzupełnia wcześniejszą dyskusję o wymagany scenariusz LAN seed → offsite VPN.