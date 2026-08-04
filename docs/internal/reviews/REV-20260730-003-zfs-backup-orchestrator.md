# REV-20260730-003 — review początkowej implementacji `zfs-backup.sh`

- Reviewer: ChatGPT
- Data: 2026-07-30
- Zakres: `fe4fb2d..fe1492f`
- Stan: **OPEN — implementacja nie jest jeszcze gotowa do użycia produkcyjnego**
- Priorytet UX: kompetentny administrator ogólny („admin po uniwerku”), nie autor skryptów

## Podsumowanie

Kierunek techniczny jest dobry:

- powstał osobny wrapper zamiast rozbudowy `deploy.sh`;
- wrapper używa istniejących backendów;
- dodano wpisy `test/deps.conf` i testy lokalne;
- `gen-cron.sh` jest uruchamiany walidacyjnie przed instalacją;
- dwa błędy wykryte podczas testu na żywo zostały szybko rozpoznane i naprawione (`keep`/`retain`, utrata produkcyjnych wpisów cron po użyciu innego pliku źródłowego).

Jednak aktualny wrapper nie realizuje jeszcze kilku uzgodnionych elementów podstawowego produktu. Najważniejsze blokady opisano poniżej.

---

## F1 — P1 BLOCKER: brak trwałej relacji LAN/VPN i brak `HostKeyAlias`

Aktualny rekord klienta przechowuje tylko `PEER_HOST`, a ta wartość jest jednocześnie używana do:

- połączenia SSH;
- wyliczenia `peer_label`;
- ścieżki targetu;
- odnalezienia manifestu i kluczy.

Zmiana adresu LAN na adres VPN zmieni więc logiczną tożsamość peera i może zmienić target. W generowanych flagach nie ma również uzgodnionego:

```text
-O HostKeyAlias=zfs-client-<client_id>
```

To oznacza, że podstawowy scenariusz:

```text
full LAN -> incremental LAN -> zmiana endpointu -> incremental VPN
```

nie jest obecnie zaimplementowany.

### Wymagane rozstrzygnięcie

- stałe `client_id`/`relation_id` niezależne od adresu;
- osobne endpointy `lan` i `vpn` albo jeden jawnie aktywny endpoint;
- stały `host_key_alias`;
- zmiana endpointu nie może zmieniać targetu, job ID, bookmarków ani plików stanu;
- test end-to-end bez `-f` po zmianie endpointu.

**Pytanie do implementera:** jaki jest plan dodania endpointu VPN bez zmiany `peer_label` i istniejącego targetu?

---

## F2 — P1 BLOCKER: brak przypiętego host key kończy się trybem fail-open

W `activate-client` brak pliku `known_hosts` generuje tylko ostrzeżenie:

```text
job would fall back to accept-new
```

To jest sprzeczne z uzgodnionym stanowiskiem. W prostym procesie brak zatwierdzonego fingerprintu ma zatrzymać aktywację. TOFU/`accept-new` może pozostać wyłącznie opcją ekspercką.

### Wymagane zachowanie

- `activate-client` odmawia pracy bez przypiętego host key;
- jeden fingerprint pve2 jest zatwierdzany niezależnie podczas inicjalizacji;
- ten sam fingerprint obowiązuje dla LAN i VPN przez stały `HostKeyAlias`;
- zmiana fingerprintu wymaga osobnej procedury.

---

## F3 — P1 UX BLOCKER: operator nadal musi znać datasety i backend `deploy.sh`

Aktualne polecenie wymaga:

```sh
zfs-backup.sh add-client NAME --peer=HOST --datasets="A B"
```

Następnie komunikat każe na pve2 ręcznie wykonać:

```sh
./deploy.sh --join=<package>
```

To nadal jest interfejs autora skryptów, nie „admina po uniwerku”. Ponadto uzgodniony model zakładał, że pve2 zatwierdza zakres udostępnianych danych, a pve1 po enroll odkrywa efektywnie dostępne datasety.

### Oczekiwany poziom UX

Administrator powinien wykonywać operacje produktowe, np.:

```sh
zfs-backup add-client pve2
zfs-backup enroll /root/pve1-enroll.tgz
zfs-backup activate-client pve2
```

Nie powinien znać `--pair`, `--join`, `--peer-datasets` ani ręcznie budować listy datasetów po stronie pve1.

**Pytanie do implementera:** czy obecne wymaganie `--datasets` jest tylko przejściowym bootstrapem, czy proponowaną finalną ścieżką? Jeżeli przejściowym — proszę wskazać etap, w którym pve2 wybiera datasety, a pve1 je odkrywa.

---

## F4 — P1 BLOCKER: realny plik config jest modyfikowany przed walidacją, dry-runem i potwierdzeniem

`activate-client` dopisuje template i sekcje `[dataset:]` bezpośrednio do produkcyjnego pliku config, a dopiero później:

1. waliduje go;
2. wykonuje dry-run;
3. pyta użytkownika o aktywację.

Jeżeli walidacja albo dry-run nie przejdzie lub użytkownik odpowie „nie”, cron nie zostanie natychmiast zainstalowany, ale niezatwierdzone joby pozostaną w pliku źródłowym. Późniejsze niezależne `gen-cron.sh --install` może je aktywować bez zgody użytkownika.

To narusza obietnicę „nothing installed / nothing changed before confirmation”.

### Wymagana poprawka

- przygotować kopię roboczą configu;
- dopisać sekcje do kopii;
- zwalidować kopię;
- wykonać dry-run;
- pokazać plan i uzyskać potwierdzenie;
- dopiero wtedy atomowo zastąpić właściwy config i zainstalować cron;
- przy każdym błędzie usunąć kopię i nie zmieniać źródła prawdy.

Analogicznie `remove-client` powinien pracować transakcyjnie i posiadać możliwość przywrócenia pliku, gdy `gen-cron.sh --install` zawiedzie.

---

## F5 — P1 BLOCKER: zabezpieczenie źródła crontaba porównuje tylko basename

Nowe zabezpieczenie po realnym incydencie jest potrzebne, ale obecna kontrola uznaje za ten sam plik:

```text
/root/prod/jobs.conf
/tmp/test/jobs.conf
```

ponieważ porównuje wyłącznie `basename`. To pozostawia dokładnie ten sam typ ryzyka: inny plik o tej samej nazwie może zastąpić cały zarządzany blok crontaba.

Dodatkowo `setup-server` może odczytać ze znacznika względną ścieżkę i interpretować ją względem aktualnego katalogu uruchomienia wrappera.

### Wymagana poprawka

- porównywać kanoniczną tożsamość pliku, nie samą nazwę;
- preferować absolutną ścieżkę zapisywaną przez `gen-cron.sh`;
- do czasu migracji względnych wpisów rozwiązywać ścieżkę jednoznacznie albo odmawiać instalacji z czytelną instrukcją;
- `assert_cron_config_matches_installed` wykonać **przed** modyfikacją configu.

---

## F6 — P1 PRODUCT BLOCKER: brak fazy `seed` i aktywacji dopiero po VPN

Wrapper ma `add-client` i `activate-client`, ale nie ma operacji prowadzącej użytkownika przez:

- pełny seed w LAN;
- końcowy catch-up w LAN;
- oznaczenie `seed_complete`;
- zmianę endpointu na VPN;
- test incrementalu przez VPN;
- dopiero wtedy instalację produkcyjnego crona.

Obecny `activate-client` od razu instaluje harmonogram po zwykłym dry-runie. Jeżeli zostanie wykonany w fazie LAN, narusza uzgodnioną zasadę „cron dopiero po pozytywnym teście VPN”.

### Minimalna maszyna stanów

Nazwy są robocze, ale system musi rozróżniać co najmniej:

```text
pending_enroll -> enrolled -> seeding -> seed_complete -> vpn_verified -> active
```

Interfejs może być prostszy niż liczba stanów, lecz stany nie mogą istnieć wyłącznie w pamięci administratora.

---

## F7 — P1 DECISION BLOCKER: profil `standard` został ustalony bez decyzji właściciela

Uzgodniony dokument pozostawił dokładny harmonogram i retencję profilu `standard` jako otwarte. Implementacja przyjęła:

```text
hourly: 24
 daily: 14
```

oraz konkretne godziny, prefiksy i progi monitoringu. To są decyzje produkcyjne wpływające na miejsce, RPO i liczbę transferów. Fakt, że podobne wartości działają na jednym istniejącym jobie pve0, nie zatwierdza ich jako globalnego profilu produktu.

Do czasu decyzji właściciela wrapper może:

- generować profil roboczy oznaczony jako niezatwierdzony i nie instalować go;
- albo poprosić o wybór jednego prostego profilu, którego wartości są jawnie opisane;
- albo utrzymać pojedynczy bezpieczny profil tymczasowy wyłącznie w teście throwaway.

Nie należy aktywować tych wartości produkcyjnie bez zatwierdzenia.

---

## F8 — P2: `ensure_cron_config` sprawdza tylko template hourly

Jeżeli istnieje `[template:standard_hourly]`, ale brakuje `[template:standard_daily]`, funkcja uzna konfigurację za kompletną i niczego nie naprawi.

Każdy wymagany template powinien być sprawdzany niezależnie albo cały blok profilu powinien mieć własny jednoznaczny marker/wersję.

---

## F9 — P2 UX: `status` i `remove-client` są nadal interfejsem technicznym

`status NAME` wypisuje surowy plik shellowy. Administrator potrzebuje interpretowanego statusu, np.:

```text
Klient: pve2
Stan: seed_complete / oczekuje na VPN
Endpoint: LAN 192.168.x.x
Fingerprint: zatwierdzony
Cron: nieaktywny
Następny krok: ustaw endpoint VPN i uruchom test
```

`remove-client` wykonuje destrukcyjne zmiany bez wcześniejszego planu i potwierdzenia. Powinien pokazać, co zostanie usunięte lokalnie, czego nie usunie z danych oraz jakie czynności pozostaną na pve2.

---

## Wymagania przed dalszym testem na produkcyjnym crontabie

1. Zamknąć F4 i F5 — wszystkie zmiany config/crontab muszą być transakcyjne i jednoznacznie związane z jednym plikiem źródłowym.
2. Nie testować `activate-client --yes` na istniejącym produkcyjnym configu, dopóki nie ma automatycznej kopii, diffu i rollbacku.
3. Następny live test wykonać na throwaway datasecie oraz izolowanym configu/crontabie albo na osobnym użytkowniku testowym.
4. Przed uznaniem funkcji za gotową wykonać test akceptacyjny LAN -> VPN z zachowaniem tego samego targetu i incrementalu.

## Ocena końcowa

Implementacja jest wartościowym szkieletem i potwierdza, że istniejące backendy można opakować. Nie jest jeszcze jednak prostym produktem zgodnym z uzgodnioną architekturą. Obecnie to nadal cienki wrapper nad `deploy.sh`, z brakującą fazą seed/VPN i kilkoma niebezpiecznymi skutkami ubocznymi w zarządzaniu wspólnym configiem crona.

**Rekomendacja:** wstrzymać dalszą rozbudowę profili i kosmetykę CLI. Najpierw zamknąć F1–F6, następnie wrócić do prostoty komunikatów i profilu `standard` po decyzji właściciela.
