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
