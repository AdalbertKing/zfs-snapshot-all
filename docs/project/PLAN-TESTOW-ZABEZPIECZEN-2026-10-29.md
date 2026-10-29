# Plan testów czterech zabezpieczeń przed wdrożeniem na resztę produkcji (2026-10-29)

Właściciel, 2026-10-29: „Chcę mieć na pewno monitoring, bezpiecznik przepełnienia puli, strażnik
ransomware i przeniesienia VM do drugiego hosta. To będę chciał jeszcze niezależnie dobrze wytestować.
Szczególnie, że model 1 kolektor robiący zdalnie na hostach migawki preferuję.”

Ten dokument to tylko plan. Nic tu nie zostało wykonane poza odczytami (`--plan`, listy, statusy).

## 0. Model i zasady

- **Model:** jeden kolektor (B, na Metropolis pve2) robi i przycina migawki NA źródle (A, pve1) przez ssh
  (relacje „migawki zdalne”). A nie ma własnych linii migawek ani retencji, tylko pakiet, konto relacji
  i linie hosta w cronie roota: `check-pool-capacity.sh` (codziennie), `capacity-guard.sh` (co 15 min),
  `growth-guard.sh` (co godzinę), `alert-digest.sh` (dzienny mail). Kopie danych A leżą na B
  (`hdd/backups/pve2/...`), często z repliki pvesr.
- **Gdzie testujemy:** lab pve9, pve9b, pve10, pve11 bez pytania. Na Metropolis tylko labowy CT 990
  (`zfslab-pvesr`, 2 GB, pvesr 990-0 pve1 -> pve2 co 15 min) i tylko za zgodą na każdy krok, który
  zmienia hosty (decyzja właściciela 2026-10-16).
- **Pul produkcyjnych nie zapełniamy nigdy.** Test pełnej puli robimy na małej puli labu: `replab`
  (960 MB) albo `gwlive` (3,75 GB) na pve10.
- Każdy test ma kontrolę negatywną: ten sam przebieg bez warunku, który ma wywołać alarm, i wtedy
  alarmu być nie może.

## 1. Stan dziś (zmierzony 2026-10-29)

| zabezpieczenie | pve2 (kolektor) | pve1 (źródło) |
|---|---|---|
| monitoring wieku migawek | linie `check-snap-age.sh` w cronie konta, także dla migawek na pve1 (przez ssh) | brak własnych, pilnuje go pve2 |
| dzienny mail, „cisza, kanał sprawny” | 07:00, cichy raport w poniedziałki | 07:00, własny, ale dowodzi tylko drogi maila z pve1 |
| alarm zajętości puli (`check-pool-capacity.sh`) | 90%, 08:00 | 90%, 08:00 |
| bezpiecznik pełnej puli (`capacity-guard.sh`) | **wyłączony**; `--plan` wskazałby najstarsze `automated_daily` własnego `rpool/ROOT/pve-1` | **wyłączony**; `--plan`: „NIC nie usunie: brak lokalnych linii retencji z jawnym wzorcem -- nie wiem, które migawki są nasze” |
| strażnik przyrostu (ransomware) (`growth-guard.sh`) | **wyłączony**; `--plan` liczy przyrost na kopiach danych pve1 (`hdd/backups/pve2/...`) i na własnych datasetach | **wyłączony**; `--plan`: „Brak naszych datasetów” |
| strażnik przeniesienia gościa (`--pve-guests`) | **działa od 2026-10-29**: 28 linii, także drzewa `hdd/vm-disks` i `rpool/data` na pve1; biegi rc 0 | sprawdzany z pve2 |

## 2. Luki w modelu jednego kolektora (do decyzji właściciela)

**L1. Bezpiecznik pełnej puli nie chroni źródła.** Bezpiecznik zna „nasze” migawki tylko z LOKALNYCH
linii retencji (`delsnaps.sh` bez `host:`). Na pve1 takich linii nie ma, więc gdy pula pve1 dojdzie do
progu, bezpiecznik wyśle alarm „NIE zadziałał”, ale niczego nie usunie. Na pve2 linie retencji pve1 są
zdalne, więc bezpiecznik pve2 też ich nie rusza. Do wyboru:
- A: kolektor przy każdym biegu przycinania zostawia na źródle opis swoich rodzin (np. w zakresie
  relacji, który źródło już przechowuje), a bezpiecznik źródła czyta ten opis;
- B: bezpiecznik działa z kolektora: pve2 sprawdza zajętość pul pve1 przez ssh i przycina zdalnie;
  gdy pve2 leży, nie działa (tak jak migawki);
- C: zostaje sam alarm zajętości (90%), a usuwanie robi człowiek.

**L2. Strażnik ransomware widzi źródło tylko przez kopie.** Na pve1 nie ma czego pilnować, na pve2
pilnuje kopii, więc zaszyfrowanie danych na pve1 zauważy dopiero po najbliższej kopii (dla migawek
godzinowych do 1-2 godzin, dla kopii z repliki pvesr dodatkowo do kadencji pvesr). Do wyboru:
- A: przyjąć to opóźnienie (najprostsze, nic nie zmieniamy);
- B: strażnik na pve2 liczy też przyrost migawek NA źródle przez ssh (`zfs send -nP` zdalnie).

**L3. Nikt nie zgłasza, że kolektor leży.** Migawki na pve1 robi pve2, więc gdy pve2 leży, migawki
stają i nikt tego nie zgłasza: monitor wieku działa na pve2, a mail z pve1 dowodzi tylko drogi maila
z pve1. Jedynym sygnałem jest brak poniedziałkowego maila z pve2, a to musi zauważyć człowiek. Do wyboru:
- A: lekki strażnik na pve1 (linia hosta): „najnowsza migawka rodziny kolektora starsza niż N godzin
  -> alarm z pve1”. W projekcie jednego kolektora §8.1 właściciel przyjął, że gdy B leży, migawki na A
  stają; otwarte zostało tylko „awaryjna relacja na A” -- alarmu z A tam nie ma;
- B: zewnętrzny „dead man's switch” (projekt jednego kolektora, §5), np. usługa sprawdzająca, czy
  codzienny mail przyszedł;
- C: zostaje jak jest: człowiek zauważa brak poniedziałkowego maila.

**L4. Strażnik przeniesienia nie był sprawdzony prawdziwą migracją.** Testy jednostkowe i lab (`-X`)
przeszły, kontrola pozytywna z konta produkcyjnego też (rc 76 dla „złego” węzła), ale gość jeszcze
nigdy nie przeszedł na drugi węzeł. Test T4 to zamyka.

Uwaga do włączania: pve1 ma config (`jobs.pve1.v4.conf`), ale bez lokalnych linii retencji, więc
włączenie strażnika przyrostu na pve1 dziś nic nie da: nie ma czego pilnować, nie będzie ani alarmu,
ani ostrzeżenia. Bez configu byłby co godzinę alarm „strażnik przyrostu NIE działa w całości”.

## 3. Testy

### T1. Monitoring (lab: pve10 kolektor, pve11 źródło, relacja „migawki zdalne”)

1. Kontrola: relacja chodzi, `check-snap-age` daje OK, w dziennym mailu nic.
2. Migawki „za stare”: w szablonie relacji testowej obniżyć progi monitora (`monitor_warn = 10m`,
   `monitor_crit = 20m`) i przeliczyć cron. Między biegami godzinowymi ma przyjść ostrzeżenie, a potem
   alarm, w dziennym mailu z nazwą relacji i datasetu. (Nie `pause-client`: pauza wstrzymuje też monitor
   relacji, który wtedy z założenia zwraca OK.)
3. Monitor nie może sprawdzić: na pve11 zablokować klucz relacji (`disable-client`). Ma przyjść
   „monitor BROKEN” (rc 3), a nie cisza.
4. Cichy raport: `zfs-backup.sh settings set alerts.all_ok_mail=<dzisiejszy dzień, np. thu> --yes`
   na pve10. Ma przyjść mail „cisza, kanal sprawny (raport okresowy)”.
5. Kolektor leży (dokumentuje L3): zatrzymać cron na pve10 na 2 godziny. Oczekiwany wynik dzisiejszego
   kodu: z pve11 nie przychodzi nic. Zapisać jako dowód do decyzji L3.
6. Przywrócić: progi monitora, `enable-client`, cron, `alerts.all_ok_mail=mon`.

### T2. Bezpiecznik pełnej puli (lab: pve10, pula `replab` 960 MB)

1. Przygotować na `replab` dataset z relacją lokalną i lokalną retencją (`delsnaps` bez `host:`), kilka
   migawek rodziny `automated_hourly_`, jedna migawka z `zfs hold`, jedna rodziny `__replicate_`.
2. `capacity-guard.sh --plan`: lista kolejności usuwania. Nie może zawierać migawki z hold,
   najnowszej, `__replicate_` ani bazy transferu.
3. Zapełnić pulę losowymi danymi (`dd if=/dev/urandom` do pliku w datasecie) do 91%. Oczekiwane:
   `check-pool-capacity.sh` ostrzega (90%).
4. Włączyć bezpiecznik tylko na pve10: `zfs-backup.sh settings set capacity.guard=on --yes`. Najbliższy bieg (do 15 min) usuwa najstarsze migawki
   rodziny, aż zajętość spadnie do 85%, i przysyła mail z listą. Sprawdzić, że migawki z punktu 2
   zostały.
5. Kontrola negatywna: pula poniżej 89% -- bezpiecznik nie robi nic.
6. Źródło w modelu jednego kolektora (dowód L1): to samo na pve11, gdzie migawki robi i przycina pve10
   zdalnie. Oczekiwany wynik dzisiejszego kodu: alarm „NIE zadziałał”, nic nie usunięte.
7. Sprzątanie: usunąć plik i dataset testowy, `settings set capacity.guard=off --yes`.

### T3. Strażnik ransomware (lab: pve11 źródło, pve10 kolektor z kopią)

1. Dataset z `compression=lz4`, migawki co godzinę, co najmniej 3 pary w historii (strażnik potrzebuje
   historii, żeby znać normę), zwykłe zapisy (tekst, małe pliki).
2. `zfs-backup.sh settings set growth.alert=on --yes` na pve10 (tam pilnowana jest kopia); `--plan`:
   wszystko „w porządku”.
3. Atak: na pve11 zapisać 2 GB danych nieściśliwych (`openssl rand`), jak zaszyfrowane pliki. Po
   najbliższej migawce i kopii: na pve10 alarm „PODEJRZANY PRZYROST” (tempo co najmniej 5 razy ponad
   normę, przyrost co najmniej 1 GiB, kompresja przyrostu do 110%). Zmierzyć czas od zapisu do maila.
4. Kontrola negatywna: zapisać 2 GB zer (ściśliwych). Alarmu ma nie być.
5. Strażnik na źródle (dowód L2): `growth-guard.sh --plan` na pve11: „Brak naszych datasetów”.
6. Sprzątanie: usunąć dane, `settings set growth.alert=off --yes`.

### T4. Przeniesienie gościa (Metropolis, labowy CT 990; każdy krok za zgodą)

1. Stan wyjściowy: CT 990 na pve1, `pvesr` 990-0 pve1 -> pve2 OK, linie pve2 dla `hdd/vm-disks` na pve1
   chodzą z rc 0.
2. **Zgoda:** `pct migrate 990 pve2` (CT zatrzymany, migracja z repliką). Oczekiwane: replikacja zmienia
   kierunek (pve2 -> pve1), na pve1 zostaje replika `hdd/vm-disks/subvol-990-disk-0`.
3. Najbliższa migawka drzewa `hdd/vm-disks` na pve1 (o :24) rusza z `-X` na `subvol-990-disk-0`
   i przysyła ostrzeżenie „guest disks left out”. Pozostałe dyski drzewa mają nowe migawki, subvol-990
   nie ma.
4. Najbliższe przycinanie drzewa `hdd/vm-disks` na pve1 (o :04) NIE rusza: END rc=76 i alarm.
5. `pvesr status` na obu węzłach: bez błędów (strażnik nie przeszkadza replikacji).
6. **Zgoda:** `pct migrate 990 pve1` z powrotem. Najbliższe biegi wracają do normy: rc 0, bez ostrzeżeń,
   przycinanie nadrabia.
7. Zapis decyzji: projekt jednego kolektora (§4 pkt 4, odpowiedź §8.2) mówił „gość przeszedł na B ->
   relacja się zatrzymuje (pomija bieg + alarm)”. 2026-10-29 właściciel wybrał dla drzew wariant A:
   migawka `-R` rusza bez dysku tego gościa (`-X`, ostrzeżenie), przycinanie drzewa stoi (rc 76, alarm);
   pojedynczy dysk gościa nadal się zatrzymuje. Otwarte zostaje, czy po migracji gościa kopia ma iść
   za nim (z nowego węzła), czy wystarczy alarm.

## 4. Kolejność i czas

T4 jest najkrótszy i najważniejszy dla modelu (dwie zgody, ok. 2 godziny z czekaniem na biegi). Potem
T1 (ok. pół dnia, głównie czekanie na progi), T2 i T3 (po ok. 2 godziny). Po testach: decyzje L1-L3,
osobne prace, a dopiero potem wdrożenie na resztę floty, host po hoście.
