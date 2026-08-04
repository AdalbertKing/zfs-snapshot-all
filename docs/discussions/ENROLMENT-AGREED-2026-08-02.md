# Uzgodnienia: uproszczony enrolment pve1 ↔ pve2

Zapis decyzji podjętych w rozmowie właściciel ↔ implementer, 2026-08-02, po
REV-20260802-033. Dokument rośnie w trakcie dyskusji; **nie jest** odpowiedzią
na recenzję ani projektem do implementacji. Kolejność: dyskusja → uzgodniony
stan → implementacja → testy.

Scenariusz odniesienia (słowa właściciela): *odpalam na pve1 nowe połączenie do
pve2, nie znam jeszcze datasetów, znam target albo wprost go nie daję dla trybu
synchro; generuję wsad, przenoszę na pve2, dostaję gotowy domyślny config dla
pve1 ubogacony o `zfs list` za komentarzami; config ląduje na pve1 i zaczyna się
backup.* Cel nadrzędny: **maksymalne uproszczenie, zjadliwe dla „admina po
uniwerku"**.

---

## U1. Miejsce edycji: **pve2**

Admin edytuje wybór datasetów **na źródle**, nie na kolektorze.

Skutek, dla którego to jest istotne: przepływ jest **jednokierunkowy**. Plik
powstaje na pve2, tam jest edytowany, tam nadaje granty i dopiero potem jedzie
na pve1. Gdyby edycja była na pve1, plik musiałby **wrócić** na pve2, żeby
cokolwiek nadać.

## U2. Nadanie grantów: **osobna, świadoma komenda**

Nie w tym samym uruchomieniu co edycja. Uzasadnienie właściciela: *„plik człowiek
będzie edytował wielokrotnie, może zrobić literówkę, zmienić zdanie. Finalizuje
świadomie komendą."*

Finalizacja jest **punktem uzgodnienia stanu**, nie przyciskiem „zapisz":

1. parsuje fail-closed — literówka, nieznany klucz, zdublowana sekcja → odmowa i
   powrót do **tego samego pliku**, nie na początek procedury;
2. pokazuje różnicę wobec **stanu nadanego dziś**, nie wobec poprzedniej wersji
   pliku (po trzeciej edycji człowiek nie pamięta, co już poszło);
3. dopiero wtedy nadaje.

## U3. Zawężenie **odbiera** — ale tylko to, co ta relacja nadała

Usunięcie datasetu z pliku i ponowna finalizacja **odbiera** grant.

Powód: bez tego plik przestaje opisywać rzeczywistość, a po miesiącu konto ma
uprawnienia, których żaden config nie tłumaczy.

Twarde ograniczenie: odbiera się **wyłącznie to, co ta relacja sama nadała**.
Manifest relacji już dziś trzyma tę listę (`PEER_SAVED_DATASETS`). Grant z innego
configu, starszego wdrożenia albo ręcznej roboty jest dla finalizacji
**niewidzialny** i ma taki pozostać — `DEPLOY-UX-AGREED-POSITION.md` §11:
automatyczne usuwanie cudzych i odziedziczonych grantów pozostaje zabronione.

To jest ten sam kształt co REV-20260802-028 (`--allow-quiesce` kasujące cudze
wpisy), z **odwrotną** odpowiedzią — i to jest celowe. Tam whitelista była
wspólna dla całego hosta, więc nadpisanie kasowało cudzą pracę. Tu zakres
należy do jednej relacji i jest w jej manifeście.

---

## Ustalenia techniczne wynikające z powyższych

### T1. Stan spoczynkowy między `--join` a finalizacją

pve2 ma konto i klucz, **zero uprawnień ZFS**. Kolektor może się połączyć i nie
może zrobić nic poza `zfs list` — czego i tak potrzeba, bo `zfs allow` ogranicza
operacje, nie listowanie. Bezpieczny stan pośredni, nie luka.

### T2. Powrót pliku na pve1 nie wymaga nowego zaufania

Po `--join` pve1 ma klucz, który pve2 akceptuje. Plik wraca tym samym łączem,
którym potem pojedzie seed. Żadnej nowej usługi, żadnego demona, żadnego tokenu
— połowa REV-033 F5 rozwiązuje się sama.

### T3. Skrót pliku zamiast drugiego manifestu

Finalizacja zapisuje **skrót pliku, z którego nadała**. pve1 przy aktywacji
sprawdza, że pobrany plik ma ten sam skrót; rozjazd = odmowa z komunikatem „na
pve2 nadano z innej wersji tego pliku", zamiast cichego backupu połowy zakresu.

Skrót nie jest drugą reprezentacją zakresu — jest stwierdzeniem, że
reprezentacja jest jedna. REV-033 F2 zabrania drugiego manifestu, nie sumy
kontrolnej.

### T4. Odebranie grantu a wiszące holdy — do rozstrzygnięcia przy implementacji

`snapsend`/`snapget` zakładają hold `zfssnapall_inflight` na czas transferu.
Jeżeli finalizacja odbierze `release` na datasecie, na którym taki hold został,
**nikt poza rootem nie zdejmie go z powrotem** — a hold na datasecie
replikowanym przez pvesr potrafi zablokować replikację PVE na dobre.

Finalizacja musi więc przy zawężeniu albo odmówić, dopóki hold tej relacji
istnieje, albo zdjąć go przed odebraniem uprawnienia. Nie wolno jej po prostu
wykonać `zfs unallow` i zostawić hold bez właściciela.

---

## Poprawka do wcześniejszego zapisu

`DEPLOY-PRECONDITIONS.md` twierdził, że pairing jest offline. **Nie jest.**
`--pair` uruchamia `ssh-keyscan` na peerze, przypina odebrany klucz hosta i
kończy błędem, gdy host jest nieosiągalny. Offline jest wyłącznie **przeniesienie
paczki**. Poprawione tam na miejscu.

Znaczenie dla F5: „online" nie jest nową zdolnością — sieć jest wymagana już
dziś. Otwarte pytanie jest węższe: **czym uwierzytelnić dostarczenie paczki**,
skoro w tę stronę nie ma jeszcze żadnych poświadczeń.

---

## U4. Plik niesie **sam zakres**; polityka zostaje na pve1

W pliku: które datasety, czy z rodzicem, czy z dziećmi, co wykluczyć. Poza
plikiem: harmonogram, retencja, `use_template`, ścieżki kluczy, target — to jest
polityka **kolektora**.

Powód: config `gen-cron.sh` niesie drabinę GFS i szablony crona. Gdyby poszedł na
pve2, admin źródła musiałby wybierać retencję, żeby oddać dwa datasety — czyli
dokładna odwrotność celu. To jest zresztą dzisiejsza ściana: draft wymaga
ręcznego `use_template = <WYBIERZ ISTNIEJACY>`.

To **nie łamie** wymogu REV-033 F2 (jedna reprezentacja). Plik zakresu jest
jedyną reprezentacją **wyboru**; config crona na pve1 jest z niego
**wygenerowany**, jak binarka z kodu. Drugą reprezentacją byłaby druga lista
datasetów, którą ktoś może edytować niezależnie — takiej nie będzie.

## U5. Wykluczenia: **jawne ścieżki z głębokością**, nie regex

```ini
[dataset:rpool/data]
include_parent   = no
include_children = yes
exclude      = rpool/data/vm-999-disk-0   # sam ten dataset
exclude_tree = rpool/data/scratch          # ten i wszystko pod nim
```

Dwa słowa zamiast wzorca, bo różnica „ten" kontra „ten i poddrzewo" **jest** tą
głębokością i nie ma powodu wyrażać jej regexem.

Dzisiejsze `-X` to **nieukotwiony** regex: `-X 'lxc'` wyrzuca `hdd/lxc` z całym
poddrzewem, ale też `rpool/data/mylxcbackup`. Dla nas to działa, bo wiemy co
piszemy; dla admina edytującego plik w `vi` to mina. Regex zostaje w trybie
eksperckim — `snapsend -X` nikomu nie jest odbierany.

Walidacja: wykluczenie musi leżeć **pod** którymś z włączonych korzeni, inaczej
odmowa. Literówka wychodzi przy finalizacji, nie po pierwszym backupie.

## U6. Prefiksy zastrzeżone na kopiach kolektora: `__replicate_:2`, `vzdump:2`

Pytanie właściciela: skąd pve1 ma wiedzieć, że na pve2 są snapshoty `__replicate_`,
skoro ich nie widzi. Odpowiedź w dwóch częściach.

**Nie musi ich widzieć.** Chronią dwie niezależne warstwy: linia prune dostaje
**wzorzec** (`automated_`) i rozważa wyłącznie pasujące snapshoty — także pod
`-G`; a `delsnaps.sh` ma wbudowaną tablicę `__replicate_/__migration__/vzdump =
all`, która jest wiedzą o Proxmoksie, nie o konkretnym hoście.

**I nie jest ślepy.** Po `--join` pve1 może wylistować snapshoty na pve2 kluczem
parowania — `zfs allow` ogranicza operacje, nie listowanie. Ten sam mechanizm,
którym `--draft-config` już dziś enumeruje datasety peera.

**Realne ryzyko jest odwrotne.** Domyślna wysyłka to `zfs send -I`, ze
snapshotami pośrednimi — więc `__replicate_*` z pve2 **lądują na pve1**, gdzie
ochrona `all` czyni je nieśmiertelnymi, a żadna replikacja ich nie używa.
`delsnaps.sh` mówi to wprost w komentarzu: *„Absolute protection made that
garbage immortal"* — i po to powstało `-P`.

**Decyzja właściciela: `-P "__replicate_:2"`** w generowanej linii prune
kolektora (rozważane `:1` i `:0`; wybrane `:2` jako bezpieczniejsze). To jest
decyzja pve1 o **własnych kopiach** i nie wymaga wiedzy o pve2.

### T5. Spis prefiksów jako komentarz w pliku

pve2 widzi rodziny snapshotów, które u niego występują, więc wypisuje je obok
`zfs list`. Zero kosztu, żadnej drugiej reprezentacji, a znika efekt „skąd mam
wiedzieć, co tam jest".

### U6a. `vzdump` też dostaje `:2`; `__migration__` zostaje `all`

Ta sama logika co wyżej i ten sam brak właściciela: `vzdump` na źródle jest
przejściowy — vzdump zakłada snapshot i sam go kasuje — ale jego **kopia** na
kolektorze zostaje na zawsze, bo tam vzdump nigdy nie biegnie. Przy regularnych
kopiach Proxmoksem to jest najszybciej rosnąca rodzina ze wszystkich trzech.

`__migration__` zostaje na `all`: powstaje tylko przy migracji guesta między
węzłami, więc nie rośnie, a `all` jest ostrożniejszym domyślnym.

> **ZMIENIONE później tego samego dnia (U11, pkt 2): właściciel zrównał
> wszystkie trzy do `:2`.** Ten akapit zostaje jako zapis rozważanej
> alternatywy, nie jako obowiązujący stan.

Ochrona liczy się **per dataset, per prefiks** — `:2` to dwa snapshoty na
dataset, nie dwa na pulę.

Generowana linia prune kolektora niesie zatem:

```
-P "__replicate_:2" -P "vzdump:2"
```

`__migration__` nie jest wymieniany, więc zostaje przy wbudowanym `all`.

---

## U7. Tryb sync: cel istniejący — kryterium to **rozjazd**, nie wiek

Pierwsza propozycja („odmawiaj każdego istniejącego celu") była za ostra i
właściciel ją przewrócił jednym pytaniem: *a jeśli cel jest starszy niż źródło,
widzisz przeciwwskazania do incremental send?*

Nie ma przeciwwskazań. „Starszy" i „rozjechany" to dwie różne rzeczy, mylone bo
zwykle chodzą razem:

- czubek celu istnieje na źródle i **nic** do celu nie pisało → `zfs send -I`
  wchodzi czysto, rollback nie jest potrzebny, `-F` jest pustą operacją;
- czubek celu istnieje na źródle, ale po nim **coś zapisano** → odbiór wymaga
  cofnięcia, a `-F` wykona je bez pytania.

**Dla żywego datasetu „cel jest starszy" nigdy nie jest prawdą w tym sensie,
który się liczy.** Jego snapshoty są starsze, ale żywy czubek jest zawsze nowszy
od własnego ostatniego snapshotu. Przyrostowy odbiór do żywego datasetu
**zawsze** oznacza odrzucenie różnicy — z definicji, nie przy pechu.

Uzgodniona tabela preflightu (sync **poza** klastrem):

| Warunek | Wynik |
|---|---|
| cel nie istnieje | odbierz |
| czubek celu jest na źródle (po **GUID**) i `written@czubek = 0` | odbierz przyrostowo, **bez `-F`** |
| `written@czubek > 0` | odmowa, z liczbą („cel ma 3,2 GB zapisów po wspólnym snapshocie") |
| brak wspólnego snapshotu po GUID | odmowa — pełny resend jest decyzją człowieka |
| cel jest dyskiem żywego guesta | **odmowa bezwarunkowa**, niezależnie od powyższych |

Detektor jest tani i jednoznaczny: `zfs get -H -o value written@<czubek> <cel>`.
Porównanie po **GUID**, nie po nazwie — ta sama nazwa po obu stronach nie znaczy
tego samego snapshotu (źródło mogło zostać odtworzone albo cofnięte; mechanikę
mamy już w `snapsend -F`).

Osobno: `-F` przestaje być domyślne przy pierwszym odbiorze do ścieżki, której ta
relacja nie utworzyła. Zostaje przy kontynuacji własnej kopii, gdzie rollback
dotyczy danych, które ta relacja sama przyniosła.

### Dowód, dla którego to nie jest teoria

Stan zmierzony 2026-08-02 ok. 16:05 na klastrze 192.168.11.x:

```
pve1 (192.168.11.11) — ZYWY vsql2, VM 100, 247 GB
  rpool/data/vm-100-disk-0@automated_hourly_2026-08-02_16-01-01   16:01  <- tylko tu
  rpool/data/vm-100-disk-0@__replicate_100-0_1785679201__          16:00
pve0 (192.168.11.10) — replika pvesr, ta sama nazwa, te same 247 GB
  rpool/data/vm-100-disk-0@__replicate_100-0_1785679201__          16:00  <- najnowszy tu
```

`snapget.sh -r pve0:rpool/data/vm-100-disk-0` (sync, bez drugiego argumentu)
celuje w **dysk żywego vsql2**. Strażnik samo-synchronizacji nie zadziała (dwa
różne hosty), pula istnieje, wspólna baza **istnieje** (16:00) — a `snapget.sh`
odbiera domyślnie z `zfs recv -F`, czyli cofnąłby bazę danych do 16:00 i skasował
snapshot z 16:01.

Dziś ratuje przed tym prawdopodobnie **ZFS**, nie nasz kod: rollback zvolu
otwartego przez działającą maszynę zwykle kończy się `dataset is busy`. To nie
jest własność bezpieczeństwa — znika, gdy maszyna jest akurat wyłączona, gdy
celem jest subvol kontenera zamiast zvolu, albo gdy guest stoi na drugim węźle.

## U8. Sync między węzłami **tego samego klastra**: odmowa przy enrollmencie

Pytanie właściciela: *czy ryzyko istnieje, gdyby to odpalić na pve1 i pve2 w
klastrze, po migracji VM na drugi host?*

Tak — i migracja zamienia pomyłkę w pułapkę, bo **odwraca, która strona jest
żywa, nie dotykając naszej konfiguracji**. Po przeniesieniu guesta na pve2 nasz
sync pve2 → pve1 zaczyna pisać do datasetu, do którego pisze też **pvesr**: dwa
niezależne systemy replikacji, jeden cel, każdy kasuje snapshoty potrzebne
drugiemu. Odpowiedzią pvesr na nieoczekiwany stan jest pełny resync albo
zaklinowanie.

Ale klaster sam podaje odpowiedź. Własność guesta jest zapisana w **ścieżce** na
współdzielonym `/etc/pve` i **przenosi się razem z maszyną**:

```
/etc/pve/nodes/pve0/qemu-server/  ->  101.conf 103.conf 104.conf 107.conf
/etc/pve/nodes/pve1/qemu-server/  ->  100.conf 106.conf
```

(widok z pve1 na 192.168.11.x — widzi też cudze). Nasz helper quiesce już dziś na
tym stoi: replikę zgłasza jako `kind=absent`, bo jej config leży na drugim węźle.
Członkostwo w klastrze jest równie tanie: nazwa peera występuje w `/etc/pve/nodes/`.

**Decyzja: jeśli peer jest członkiem tego samego klastra, tryb sync jest
odrzucany na wejściu** — nie przy odbiorze — z komunikatem wskazującym tryb
backup. Powód nie jest „bywa niebezpieczny": **pvesr już to robi i robi lepiej**
(zna właściciela, przełącza kierunek przy migracji, integruje się z HA). Bylibyśmy
drugim pisarzem do cudzego celu.

Tryb **backup** wewnątrz klastra zostaje w pełni dozwolony i jest bezpieczny:
pisze do własnej przestrzeni nazw pod targetem, gdzie pvesr nigdy nie zagląda.
Dokładnie to robi dziś metropolia.

---

## U9. Endpoint: **jeden aktualny + lista kandydatów**, zamiast slotów `lan`/`vpn`

Właściciel wyliczył warianty: kolektor (A) zostaje w LAN, (B) startuje w WAN i
tam zostaje, (C) jest wynoszony z LAN do WAN — a pve2 widzi wtedy pod (a)
publicznym IP z przekierowaniem portu na routerze, (b) zupełnie innym VPN-em
(Tailscale i podobne), (c) tym samym adresem, bo OpenVPN go routuje. Sam pve1
jest przy tym widziany z różnych adresów źródłowych.

### Co nie zmienia się w żadnym z tych wariantów

**Klucz hosta pve2.** Ta sama maszyna, ten sam klucz — niezależnie od drogi.

I to jest już dziś wykorzystane poprawnie. Generowane zadania niosą:

```
-K <klucz relacji> -k <alias_known_hosts> -O HostKeyAlias=<alias>
-O GlobalKnownHostsFile=/dev/null -O CheckHostIP=no  [-p <port>]
```

Przypięcie jest **kluczowane aliasem, nie adresem**, więc zmiana adresu ani portu
go nie unieważnia. Tożsamość relacji to klucz hosta pod stałym aliasem; adres
jest tylko sposobem dojścia.

### Macierz sprowadza się do jednego pytania

Czy zmienia się `host:port`, którego używa ssh:

| Wariant | `host:port` | Działanie |
|---|---|---|
| A — pve1 zostaje w LAN | bez zmian | nic, nigdy |
| B — pve1 startuje w WAN i zostaje | ustalony raz przy enrollmencie | nic później |
| C-c — wyniesiony, OpenVPN routuje ten sam adres | **bez zmian** | **tylko weryfikacja** |
| C-a — wyniesiony, publiczne IP + przekierowanie portu | nowy host i port | jedna zmiana pola |
| C-b — wyniesiony, Tailscale/inny VPN | nowa nazwa/IP | jedna zmiana pola |

W C-a i C-b relacja przeżywa nietknięta: klucz relacji, klucz hosta, alias,
target, bookmarki i tożsamość zadań zostają.

### Odwrotny kierunek: pve1 widziany z różnych adresów

`authorized_keys` na peerze to zwykły wpis, **bez `from=`** — uwierzytelnianie
kluczem nie interesuje się adresem źródłowym. Ugryźć mogą rzeczy spoza naszego
kodu: firewall na pve2 ograniczający ssh do LAN, `sshd` `AllowUsers`/`Match
Address`, fail2ban, a w C-a dodatkowo router decydujący, co odpowiada na
przekierowanym porcie. Wszystkie objawiają się jako „nie mogę się połączyć", a
nie „brak uprawnień" — i to rozróżnienie już umiemy robić (exit 255).

**Przypięty klucz hosta zarabia tu na siebie po raz drugi.** W C-a endpoint
wskazuje na **router**, nie na maszynę. Jeśli przekierowanie kiedykolwiek trafi w
inny host, klucz się nie zgodzi i zadanie **padnie, zamiast zrobić backup nie tej
maszyny**. Dlatego `accept-new` w tej ścieżce zostaje zakazane.

### Uzgodniony model

Jeden **aktualny endpoint** + opcjonalna **lista znanych adresów**. Przeniesienie
przebiega zawsze tak samo, niezależnie od wariantu:

```
sprawdź aktualny endpoint
  -> osiągalny, fingerprint się zgadza, dry-run mówi INCREMENTAL
       -> nie zmieniaj niczego
  -> nieosiągalny
       -> wypróbuj pozostałe znane adresy
       -> dopiero gdy żaden nie działa: poproś o nowy, przypnij do TEGO SAMEGO
          aliasu, zweryfikuj przed aktywacją
```

C-c nie kosztuje wtedy nic (nikt nie wpisuje adresu, który się nie zmienił),
C-a i C-b to jedno pole, A i B nie robią nic nigdy.

Pola `ENDPOINT_LAN_*` / `ENDPOINT_VPN_*` zostają jako **wewnętrzna zgodność** dla
istniejących rekordów klientów (żeby aktualizacja nie wywróciła metropolii), ale
znikają z interfejsu.

### Potwierdzenie zarzutu recenzenta o rolach

REV-033 F4 twierdzi, że komunikaty nazywają złą maszynę. **Potwierdzone w
kodzie**, nie ma czego bronić — `cmd_final_catchup` mówi dziś *„immediately
before the **source** is physically moved"* i *„The **source** may now be
disconnected and moved"*, podczas gdy przenoszony jest **kolektor**.

---

## U10. Dostarczenie paczki online + opcjonalny zdalny `--join` i edytor przez `ssh -t`

### Warunek, który to rozstrzygnął

Admin uruchamiający `add-client` na pve1 **ma dostęp SSH do pve2** (odpowiedź
właściciela). To jest ten sam człowiek, który za chwilę poszedłby tam uruchomić
`--join`.

### Dostarczenie paczki — bez nowego prymitywu zaufania

Paczka jedzie **poświadczeniami admina**. Narzędzie nie zdobywa dostępu, którego
człowiek by nie miał.

Niuans, który to poprawia: klucz hosta pve2 jest **już przypięty** — `--pair`
pobrał go `ssh-keyscan`-em chwilę wcześniej i wypisał fingerprint do weryfikacji.
Dostarczenie jedzie po **naszym** przypięciu:

```
scp -o UserKnownHostsFile=<nasz pin> -o StrictHostKeyChecking=yes ...
```

Żadnego pytania „czy ufasz", żadnego osłabienia, ten sam klucz, którego użyje
potem relacja. Zaufanie nie jest słabsze niż samo parowanie — jest **tym samym**
zaufaniem.

Powrót pliku zakresu jedzie kluczem relacji (T2). Bilans całości: **żadnej
usługi, żadnego demona, żadnego tokenu, żadnej nowej zależności.** Ręczne
przeniesienie zostaje jako droga awaryjna.

O samej paczce warto powiedzieć wprost: nie jest tajemnicą. Niesie klucz
**publiczny** kolektora, rolę, target, nazwę konta i etykietę — zero sekretów.
Chroniona jest więc **integralność**, nie poufność: znaczenie ma, żeby na pve2
trafiła paczka od właściwego pve1. `--join` waliduje strukturę bezwzględnie
(stały zbiór kluczy, plik jako dane, nigdy `source`), ale „czy to ten kolektor"
jest i zostaje decyzją ludzką.

### Zdalny `--join` i edytor przez `ssh -t` — pod jedną jawną flagą

Pierwszy odruch implementera był przeciw. Był **odruchem z nieaktualnego stanu**:
w dzisiejszym kodzie `--join` nadaje granty, więc zdalne uruchomienie oddawałoby
uprawnienia przez kolektor. Ale **U2 to rozbroiło** — po niej `--join` zakłada
konto, przyjmuje klucz i kończy z **zerem uprawnień ZFS** (T1). Zasada „każdy
host oddaje uprawnienia u siebie" przeżywa zdalny `--join` bez zadraśnięcia,
bo chronionym aktem jest **grant**, a grant zostaje lokalny.

Decyzja właściciela: **obie rzeczy**, pod jedną jawną flagą (nazwa otwarta,
roboczo `--join-remotely`):

- zdalne uruchomienie `--join` na pve2;
- otwarcie edytora pliku zakresu przez `ssh -t`, czyli `vi` biegnie na pve2, ale
  w terminalu admina siedzącego przy pve1.

Nie przenosimy władzy — przenosimy klawiaturę. Każdy uprzywilejowany akt nadal
wykonuje się **lokalnie na pve2**, w sesji autoryzowanej przez człowieka.

Trzy warunki, bez których ta opcja nie wchodzi:

1. **Finalizacja zostaje lokalna. Zawsze.** Nie ma flagi, która to przełącza.
   Konto może założyć kolektor; uprawnienia nadaje człowiek na źródle.
2. Idzie po **naszym przypiętym kluczu hosta**, tak jak dostarczenie paczki.
   Żadnego `accept-new`, żadnego wyjątku.
3. Manifest na pve2 zapisuje, że wpis powstał **zdalnie** — z jakiego kolektora
   i czyją sesją. Za pół roku „skąd się tu wzięło to konto" musi mieć odpowiedź
   w pliku, nie w czyjejś pamięci.

Flaga **jest** deklaracją zaufania do sieci. Nie próbujemy tego wykrywać: „sieć
zaufana" nie jest własnością mierzalną i każdy test byłby udawaniem.

Domyślnie flagi nie ma — domyślną drogą zostaje dostarczenie paczki plus
wypisanie dokładnej komendy do uruchomienia na pve2.

---

## Stan dyskusji

Pięć obszarów REV-20260802-033 przegadanych, dziesięć uzgodnień spisanych.
Następny artefakt: `docs/internal/reviews/responses/REV-20260802-033.md` — odpowiedź
dokumentacyjna, bez zmian w kodzie produkcyjnym, zgodnie z żądaniem recenzji.

---

## Sprzątanie 2026-08-02 i dwie rzeczy, które przy nim wyszły

Po testach z 30 lipca / 1 sierpnia zostały na produkcji dwa osady. Usunięte, z
kopią zapasową przed każdym usunięciem.

**metropolis pve1** — manifest peera `192.168.28.8.conf` po relacji, której na
pve2 już nie było (konta `zfsbackup-pve1` brak, datasetu `uxsrcB` brak).
Sprzątnięte narzędziem projektu, nie `rm`-em: `deploy.sh --unpair
--peer=192.168.28.8`. Zdjęło klucz relacji, przypięty klucz hosta, kopie konta,
manifest i resztki paczki/draftu. **Nie ruszyło `/root/.ssh/known_hosts`** i
powiedziało dlaczego: *„to nasz zapis o tym, kim oni są, nie uprawnienie dla
nich"*. Rekord klienta `clients/pve2.conf` zostawiony — kończy się
`STATE=removed` i jest historią, nie żywym klientem.

**pve0** — `zfs-backup.conf` z testowego `setup-server` z 30 lipca, wskazujący
`CRON_CONFIG=/root/scripts/zfs-snapshot-all/jobs.pve0.v4.conf`, czyli **ścieżkę
sprzed migracji**, spod której config został przeniesiony do
`/etc/zfs-snapshot-all/`. Bezczynne (strażniki `assert_cron_config_matches_installed`
i `ensure_cron_config` by odmówiły), ale plik kłamał. Usunięty; `clients/` i
`peers/` były i są puste.

Po sprzątaniu: cztery hosty, zero żywych rekordów klienta, produkcyjne bloki
nietknięte (pve1 15 linii, pve2 11, pve0 27, pve1/11.11 7), dostęp ssh roota i
konta do pve2 potwierdzony po operacji.

### Luka: teardown nie zna pliku, który tworzy wrapper

`do_unpair` w `deploy.sh` usuwa `pairing-<label>_ed25519` i
`pairing-<label>_known_hosts`, ale **nie** `pairing-<label>_alias_known_hosts` —
bo ten plik tworzy `ensure_alias_known_hosts` w `zfs-backup.sh`, a `deploy.sh` o
nim nie wie. Został po dzisiejszym `--unpair` i zdjąłem go ręcznie.

To jest dokładnie ten kształt problemu, o który pytał właściciel: **dwa skrypty,
jedna relacja, jeden z nich sprząta tylko swoją połowę.** Do naprawy przy
implementacji — albo `do_unpair` uczy się o pliku aliasu, albo tworzenie aliasu
przenosi się do `deploy.sh`, gdzie jest reszta materiału relacji.

### Obserwacja do dyskusji o warstwach

`deploy.sh --unpair` wykonuje **najpierw cały przebieg prowizjonujący** — fazy 1,
2, 5, 6, 6a, łącznie z `git pull` repozytorium — a dopiero potem zrywa relację.
Czyli „nie każdy deploy jest parowaniem", ale **każda operacja na parze jest
deployem**. To jest materialny argument w dyskusji o rozdzieleniu warstw, a nie
tylko odczucie estetyczne.

---

## U11. Config zadań dostaje **własność per sekcja**, razem z enrollmentem

Pytanie właściciela po refaktorze crontaba: *a ilu jest pisarzy do configa?*

Trzech maszynowych plus człowiek: `zfs-backup.sh` (tworzy, dokłada sekcje per
klient, `migrate-profile`, `remove-client`), `cron2conf.sh` (`-o`), oraz
operator — który tutaj jest pisarzem **pełnoprawnym**, inaczej niż przy
crontabie. `deploy.sh` configu zadań nie dotyka. REV-033 dokłada czwartego:
plik zakresu edytowany na pve2.

Dlatego „jeden pisarz" jest tu **złą odpowiedzią** — znaczyłoby odebranie
człowiekowi edytora. Uzgodniony cel to **własność per sekcja**:

- sekcje generowane niosą marker mówiący, kto i dla którego klienta je
  utworzył, więc `remove-client` usuwa **swoje**, a nigdy ręcznie napisaną
  sekcję nazywającą przypadkiem ten sam dataset. Dziś `remove_managed_sections`
  dopasowuje **po nazwie datasetu** — ten sam kształt „brak właściciela znaczy
  zgadywanie", który miały luźne linie w crontabie;
- plus **skrót pliku** uzgodniony już jako T3, żeby config nie mógł się
  rozjechać z tym, co zainstalowane i nadane.

**Kiedy: razem z enrollmentem, nie osobno.** To REV-033 dokłada czwartego
pisarza i to jest powód, żeby o tym zdecydować — dokładnie tak, jak crontab był
powodem zrobienia tamtego refaktoru przed enrollmentem, a nie po nim.

Dziś nie jest to pilne i warto to powiedzieć wprost: config jest chroniony
lepiej, niż crontab był przed 2026-08-02 — `ensure_cron_config` odmawia
utworzenia pliku, o którym crontab twierdzi, że z niego powstał;
`assert_cron_config_matches_installed` odmawia instalacji z innego pliku;
`atomic_replace_and_install` odtwarza plik **i** crontab; każda instalacja
pokazuje dwa diffy; a całość jest wersjonowana w prywatnym `zfs-cron-configs`.

## Trzy pytania z odpowiedzi na REV-033 — rozstrzygnięte

1. **Nazwa flagi: `--drive-peer`.** Odrzucone `--trusted-network` i pochodne:
   nazywają cechę, której nikt nie umie sprawdzić, i czytają się jak
   zapewnienie. `--drive-peer` nazywa, co się stanie — ten host wykona kroki na
   tamtym.
2. **Prefiksy zastrzeżone: wszystkie trzy na `:2`** — `__replicate_`,
   `__migration__`, `vzdump` (zmiana wobec U6a, gdzie `__migration__` zostawał
   na `all`).
3. **Istniejący klienci migrują się tylko na jawne `--force`.** Metropolia
   działa dalej bez zmian.

---

## Wdrożenie 2026-08-03: mechanika dwóch serwerów — format pliku + działanie po SSH (plasterek 6)

Do tego wróciliśmy dziś przy budowie plasterka 6: jak DOKŁADNIE pve1
(kolektor) i pve2 (źródło) się ze sobą rozmawiają, żeby U1-U4/T1-T5 z góry
przestały być tylko uzgodnieniem i stały się działającym mechanizmem. Poniżej
stan **jak zaimplementowany**, nie projekt.

### Format pliku (pve2, źródło)

Dwa pliki, oba world-readable, w katalogu stanu parowania (`peer_scope_path`/
`peer_scope_granted_hash_path`, ten sam katalog co manifest parowania):

```
<label>.scope           # sam plik zakresu -- gramatyka niżej
<label>.scope.sha256    # T3: sha256 DOKŁADNIE tego pliku, z chwili ostatniego --commit-scope
```

Gramatyka `<label>.scope` (właścicielem jest `lib-scope.sh`, U4/U5):

```
[dataset:<pool/ścieżka>]
	include_parent   = yes | no
	include_children = yes | no
	exclude          = <pool/ścieżka>   # powtarzalne
	exclude_tree     = <pool/ścieżka>   # powtarzalne
```

Plik niesie WYŁĄCZNIE wybór datasetów (U4) — harmonogram, retencja, target
zostają po stronie kolektora. `--draft-scope` generuje go z prawdziwego
`zfs list` (aktywne datasety domyślnie: jeden poziom pod każdą pulą, poza
systemowymi), dopisuje pełny inwentarz PLUS spis rodzin snapshotów (T5) jako
komentarz — nic z tego nie jest odczytywane programowo, to wyłącznie pomoc
dla admina edytującego plik. `--commit-scope` czyta go, nadaje `zfs allow`
dokładnie na to, co plik wybiera, i **dopiero wtedy** zapisuje
`<label>.scope.sha256` — sidecar to dowód, z czego realnie nadano, nie co
akurat leży w pliku.

### Działanie po SSH (pve1, kolektor) — `resolve_mode_datasets()`

Wywoływane raz, wewnątrz `load_client_and_connection` (czyli automatycznie
przy `seed`/`verify-endpoint`/`activate-client`/`migrate-profile` — żadna z
tych komend nie wie, że coś się zmieniło). Dla klienta z `--mode=` (zamiast
`--datasets=`):

1. `ssh` (ten sam przypięty klucz/host-key co reszta relacji) pobiera oba
   pliki: `cat -- '<label>.scope'` i `cat -- '<label>.scope.sha256'`. Brak
   pierwszego → komunikat „czy `--draft-scope` już tam było?"; brak drugiego
   → „czy `--commit-scope` już tam było?" (T1: `zfs list` nie jest ograniczone
   przez `zfs allow`, więc SAM fetch działa niezależnie od kolejności obu
   komend na pve2 — ale sidecar #2 istnieje dopiero po `--commit-scope`).
2. `sha256sum` pobranego pliku porównywane z sidecarem. Niezgodność → twarda
   odmowa, nazywająca wprost „edytowano po ostatnim `--commit-scope`, uruchom
   je ponownie" (T3) — nigdy cichej generacji zadań dla zakresu, którego nikt
   faktycznie nie nadał.
3. Plik czytany przez `lib-scope.sh` (`scope_read`) — **prawdziwa krawędź
   źródłowa**, `zfs-backup.sh` teraz `source`-uje `lib-scope.sh` wprost, nie
   duplikuje gramatyki.
4. Dla każdego `[dataset:]` z pliku: `ssh ... "zfs list -H -o name -r -- '<root>'"`
   po tym samym kanale, wynik filtrowany przez `scope_includes` (ta sama
   funkcja, ten sam wybór parent/children/exclude co przy nadawaniu na pve2).
5. Wynik ląduje w `PEER_SAVED_DATASETS` — **dokładnie w tej samej postaci**,
   jakby ktoś podał `--peer-datasets="..."` ręcznie. Żaden dalszy konsument
   (seed, activate-client, `emit_client_sections`, migrate-profile) nie wie i
   nie musi wiedzieć, skąd ta lista przyszła.

Efekt końcowy zgodny ze scenariuszem odniesienia z góry tego dokumentu:
`activate-client` pokazuje diff, pyta raz, instaluje GOTOWY config z domyślną
polityką (`PROFILE_GFS`) — nie kandydatów do ręcznego składania.

### Dwie rzeczy dopięte przy okazji tej samej pracy

**U11 (znacznik własności sekcji), konkretny kształt:** pierwsza linia treści
każdej wygenerowanej sekcji `[dataset:]`/`[prune:]` to
`# managed-by: zfs-backup.sh client=<nazwa>`. `remove_managed_sections` usuwa
sekcję, gdy ten znacznik się zgadza, ALBO gdy ścieżka była już wcześniej
zapisana we własnym `MANAGED_DATASETS` wywołującego (stan sprzed znacznika —
tak istniejący klient przeżywa wdrożenie bez ręcznej migracji, znacznik
dochodzi przy najbliższym przepisaniu). Bez żadnego z tych dwóch — odmowa, nie
cicha kasacja.

**U6 (prefiksy zastrzeżone), konkretne miejsce:** `keep = 2` dla
`__replicate_`/`vzdump`/`__migration__` dopisywane przez `ensure_cron_config`
(raz na cały config, nie per klient — `[excluded:]` to mechanizm globalny w
`gen-cron.sh`), wyłącznie DOKŁADAJĄC brakujący próg.

Kod: `9f08af6`. Testy: `test/zfsbackup/run.sh` **230/230**. Odpowiedź dla
recenzenta z tym samym opisem: addendum "Slice 6" w
`docs/internal/reviews/responses/REV-20260802-033.md`.
