# Decyzja: cienkie GUI nad zfs-snapshot-all

Status: **PROJEKT DO ZATWIERDZENIA przez właściciela** (2026-09-04). Spisany
przez implementera z dyskusji z właścicielem („czy jesteś w stanie w trybie
ciągłym, z minimalną moją ingerencją, położyć na ten pakiet cienkie intuicyjne
GUI?"). Odpowiedź implementera: tak, pod warunkiem, że pięć pytań z §4
dostanie odpowiedź **raz**, przed pierwszą linią kodu. Po nich praca idzie
etapami z §5 bez dalszych pytań: jeden PR na etap, właściciel mówi „Scal" i
raz na etap z akcjami odpala runbook na labie. Żadna linia kodu GUI nie
powstała; ten dokument ma wyprzedzić pierwszą.

## 1. Co repozytorium już o GUI powiedziało

Wątki o GUI w repozytorium dotyczą **kontraktu danych**, nie formy. Żaden nie
rozstrzyga rodzaju ani wyglądu — to właśnie luka, którą wypełnia §4.

**[decyzja, 2026-08-23] Warstwa danych dla maszyn, nie tylko oczu.** Rekord
postępu niesie relację (`label`), tryb i bazę wyprowadzone z prawdziwej komendy
send (`full`/`incremental`/`resume`), tożsamość zadania i bajty na łączu
(`wire_bytes`, `-1` = niemierzalne), „żeby przyszłe GUI albo monitor mogły to
zbadać bez skrobania tekstu" (`docs/PROJECT_STATUS.md`).

**[decyzja, w kodzie] `--json` jest produktem, nie wygodą.** `progress --json`
i `list-replicas --json` mają ten sam kształt odpowiedzi — jeden obiekt, jedna
tablica rekordów, pola nazwane po polach configu, z których pochodzą — „so a
front end learns the convention once" (`zfs-backup.sh`, `cmd_list_replicas`).
Stan nośnika (`here`/`available`/`away`/`wrong_medium`) jest **pytaniem do
bramki**, nie wnioskiem z listy, bo tylko bramka odróżnia „pula
niezaimportowana" od „w slocie jest ZŁY dysk".

**[decyzja, 2026-09-01] Spójność nazw pod GUI.** „Pilnujemy spójności pakietu
na każdym etapie. To ma wejść pod GUI. Nie ma miejsca na chaos." Stąd reguła
gramatyki list w `docs/project/FOUNDATIONS.md` (lista płaska po przecinku,
lista wzorców po jednej fladze / polu numerowanym) i ujednolicone
`exclude_family` / `exclude_child_<n>`.

**[decyzja, 2026-09-01] Część wsadowa zamknięta; „kolejny etap jest po stronie
GUI, nie wsadu"** (`docs/project/OWNER-DECISIONS.md`). Etap profili nie ma
dalszych kroków.

**[dyskusja, 2026-08-17] „GUI dostaje jeden czasownik na relację."**
`ZFSBACKUP-ONLY-DEPLOYMENT` §3: pod `--force-remote` orkiestrator domyka
wszystkie zejścia i `deploy.sh` znika z rąk operatora. Ta sama dyskusja
zauważa, że jednodotykowość **nie** zwiększa świadomości klikającego
operatora — GUI nie może być argumentem za osłabieniem odmów.

## 2. Zasady niezależne od odpowiedzi

Obowiązują przy każdym wariancie z §4; nie są do dyskusji, bo wynikają z
zasad, które pakiet już ma.

1. **GUI nie skrobie tekstu.** Czyta wyłącznie `--json` i pliki stanu o
   ustalonym kształcie. Jeśli czegoś nie ma w JSON, najpierw dochodzi
   `--json` w CLI (etap A w §5), potem widok. Tekst dla ludzi zostaje dla
   ludzi.
2. **GUI nie omija odmów.** Każda akcja to wywołanie istniejącego czasownika
   CLI z jego bramkami (`--yes`, grant, podgląd, kody wyjścia z
   `docs/CONVENTIONS.md` §6). GUI nie ma własnej kopii żadnej reguły
   bezpieczeństwa i nie ma trybu „force".
3. **GUI nie dotyka silników.** Zamrożone silniki (`snapsend.sh`, `snapget.sh`,
   `delsnaps.sh`, `check-snap-age.sh`, `lib-zfs-snap.sh`) nie zmieniają się
   pod GUI. Wszystko, czego GUI potrzebuje, jest już w rekordach postępu i
   w plikach stanu, albo dochodzi w warstwie orkiestracji.
4. **Jeden czasownik na relację.** Widok relacji pokazuje jej stan i
   dokładnie te akcje, które CLI dziś dopuszcza dla tego stanu. Żadnych
   kreatorów składających kilka czasowników w jedno kliknięcie.
5. **Restore poza pierwszym zakresem.** Odtwarzanie (Faza 7) ma własny
   kontrakt z podglądem nazywającym każdy obiekt, grantem i potwierdzeniem.
   Wchodzi pod GUI dopiero jako osobny etap po labie, i tylko w formie
   bezpiecznej (do nowej przestrzeni nazw). Destrukcyjne zostaje w CLI do
   odrębnej decyzji właściciela.
6. **Bez nowej powierzchni ataku domyślnie.** Domyślna konfiguracja nie
   otwiera portu na sieć i nie wprowadza nowego mechanizmu uwierzytelniania.
   Dostęp idzie istniejącym kanałem (SSH), tak jak wszystko inne w pakiecie.
7. **Bez nowych zależności na hoście.** To, czego GUI potrzebuje w runtime,
   musi już być na Proxmoxie; `deploy.sh` nie dostaje nowej listy pakietów do
   instalacji poza tym, co §4 P3 jawnie dopuści.
8. **Ta sama dyscyplina testowa.** Kontrakty JSON dostają suitę z kontrolą
   ujemną (`test/deps.conf` `[contract:]`), widoki dostają testy na stubach,
   akcje dostają obowiązek runbooka na labie przed scaleniem.

## 3. Inwentarz warstwy danych — co jest, czego brakuje

Zmierzone 2026-09-04 na `main` `6c5c01d`.

| dana | źródło dziś | kształt | pod GUI |
|---|---|---|---|
| postęp transferów | `zfs-backup.sh progress --json` | JSON: `relations[]`, `jobs[]`, `dataset`, `target`, `label`, `state`, `done_bytes`, `total_bytes`, `updated_epoch`, `idle`/`running` | **gotowe** |
| repliki i nośniki | `zfs-backup.sh list-replicas --json` | JSON, ten sam kształt; stan nośnika z bramki | **gotowe** |
| rekordy postępu na dysku | `/var/lib/zfs-snapshot-all/progress/<klucz>.json` | JSON, jeden plik na zadanie | gotowe do odczytu bez CLI |
| stan relacji (klient, endpoint, pauza) | `zfs-backup.sh status [NAZWA]` | **tylko tekst** (`printf` z `state=` `endpoint=`) | **brakuje `--json`** |
| lista relacji z configu | `gen-cron.sh` (render), `clean-relationships.sh` | tekst / crontab | **brakuje czasownika listującego z `--json`** |
| wiek snapshotów (monitor) | `check-snap-age.sh` | kontrakt Nagios 0/1/2/3, tekst; **zamrożony** | GUI czyta kod wyjścia i linię; JSON dochodzi w warstwie orkiestracji, nie w silniku |
| pauza / hold aktualizacji | `deploy.sh --pause/--resume`, `update-hold` | pliki stanu w `/var/lib/zfs-snapshot-all/relationships`, `/root/.zfs-snapshot-all-*-state` | odczyt: pliki; akcja: przez CLI |
| historia przebiegów | logi silników (`-l`), rekordy postępu | tekst | **brakuje** ustrukturyzowanej historii; pierwsza wersja czyta rekordy, nie logi |
| digest alertów | `hostscripts/alert-digest.sh` | mail | poza GUI; GUI pokazuje to samo źródło (kody monitora), nie treść maila |

Wniosek: **przed widokiem potrzebne są trzy rzeczy w CLI**: `status --json`,
czasownik `relations --json` (lista relacji z ich stanem, jedna odpowiedź) i
`monitor --json` w warstwie orkiestracji (wywołuje zamrożony
`check-snap-age.sh` per linia i pakuje wynik). To jest etap A w §5 i nie
wymaga żadnej z decyzji §4.

## 4. Pięć pytań — z rekomendacją

Każde pytanie ma rekomendację **[propozycja]** i koszt odstępstwa. Odpowiedź
właściciela w jednym zdaniu na pytanie wystarczy.

### P1. Rodzaj: przeglądarka, konsola czy wtyczka Proxmoxa?

| wariant | za | przeciw |
|---|---|---|
| **web (przeglądarka), jeden proces, jeden plik** | działa z każdego miejsca, w którym operator ma tunel SSH; odświeżanie na żywo; ta sama strona na telefonie | wymaga procesu nasłuchującego (choćby na localhost) |
| TUI (`whiptail`/`dialog` w konsoli SSH) | zero procesu, zero portu, bash jak reszta pakietu | brak odświeżania na żywo bez pętli; nie skaluje się na widok floty; „intuicyjne" tylko dla kogoś, kto i tak jest w konsoli |
| wtyczka do panelu Proxmoxa | operator już tam jest | wiąże pakiet z wewnętrznym API `pve-manager` (ExtJS), które nie jest kontraktem; łamie zasadę „bez zależności"; Proxmox to jeden z celów pakietu, nie jedyny |

**[propozycja] Web.** Jeden proces, jeden plik, bez frameworka po stronie
serwera i bez zewnętrznych bibliotek po stronie przeglądarki (jeden plik HTML
z wbudowanym CSS/JS, odświeżanie przez `fetch` do `--json`). TUI zostaje jako
opcja później, jeśli będzie realna potrzeba; wtyczka Proxmoxa — nie.

### P2. Miejsce i dostęp: gdzie nasłuchuje i kto może wejść?

| wariant | za | przeciw |
|---|---|---|
| **tylko `127.0.0.1` na kolektorze, wejście przez tunel SSH** (`ssh -L 8xxx:127.0.0.1:8xxx root@kolektor`) | zero nowej powierzchni; uwierzytelnianie = klucz SSH, który operator już ma; nic do konfigurowania | jedna komenda więcej przed otwarciem przeglądarki |
| port na LAN z własnym hasłem | wygodniej | nowy mechanizm haseł, TLS, wygasanie sesji — cały pakiet pracy poza dziedziną projektu, i nowa powierzchnia na roocie |
| za reverse proxy Proxmoxa (`pveproxy`) | jeden adres | jak wtyczka: zależność od wewnętrznych ustaleń `pve-manager` |

**[propozycja] Localhost + tunel SSH.** Proces uruchamiany na żądanie
(`zfs-backup.sh ui` albo osobny `zfs-backup-ui`), nie jako demon na stałe;
opcjonalnie jednostka systemd, jeśli właściciel chce mieć go zawsze. Bind
poza localhost jest **odmową**, nie flagą — do czasu osobnej decyzji.

Wiąże się z tym pytanie **jako kto biegnie proces**. Tryb odczytu (P4) może
biec jako root z ograniczeniem do odczytu, bo woła tylko `--json`; akcje wołają
`deploy.sh`/`zfs-backup.sh`, które i tak wymagają roota. Konto delegowane nie
ma dostępu do stanu relacji, więc GUI jako `zfsbackup` widziałoby tylko
postęp. **[propozycja]** root, z twardą listą dozwolonych czasowników w kodzie
GUI (allow-lista, nie parsowanie dowolnej komendy z przeglądarki).

### P3. Język: w czym pisać front i proces?

| wariant | za | przeciw |
|---|---|---|
| **Python 3 z biblioteki standardowej** (`http.server`, `json`, `subprocess`) | jest w bazowym Debianie każdego hosta pakietu (do potwierdzenia jedną komendą: `python3 --version` na pve9); zero instalacji; naturalny **pierwszy moduł Pythona** w pakiecie, który nie tłumaczy niczego, tylko czyta JSON — wpisuje się w wątek `PYTHON-TRANSLATION-ESTIMATE-2026-09-03.md` | drugi język w repozytorium; harness testowy jest bashowy, więc testy GUI wołają proces z zewnątrz |
| bash + `socat`/`nc` jako serwer HTTP | jeden język | serwer HTTP w bashu to własna implementacja protokołu; `socat` nie jest w bazie |
| Node / Go / cokolwiek kompilowanego | wygoda bibliotek | zależność do instalacji na każdym hoście; łamie §2 pkt 7 |

**[propozycja] Python 3, tylko biblioteka standardowa**, jeden plik, bez
`pip`. Strona w przeglądarce bez frameworka (czysty HTML/JS wbudowany w ten
sam plik). Jeśli właściciel wybierze TUI w P1, odpowiedź zmienia się na bash +
`whiptail` (jest w bazowym Debianie).

### P4. Zakres pierwszej wersji: co widać i co można kliknąć?

| wariant | za | przeciw |
|---|---|---|
| **tylko odczyt** | zero ryzyka; nie wymaga labu; od razu użyteczne (jeden ekran zamiast trzech komend i grepowania logów) | operator nadal idzie do konsoli po każdą akcję |
| odczyt + akcje bezpieczne (pauza, wznowienie, uruchom teraz, podgląd planu) | „jeden czasownik na relację" staje się faktem | każda akcja to obowiązek runbooka na labie |
| odczyt + akcje + restore bezpieczny | pełne pokrycie Fazy 7 | restore ma najgrubszy kontrakt w pakiecie; wchodzi jako osobny etap |

**[propozycja] V1 = tylko odczyt**, w tym: relacje z ich stanem i endpointem,
postęp bieżących transferów, ostatni zakończony transfer per relacja, monitor
wieku per linia (kolory z kodów 0/1/2/3), repliki i stan nośnika, hold
aktualizacji. **V2 = akcje bezpieczne** z listy: `--pause`, `--resume`,
uruchom teraz (istniejący czasownik `run-replicas` / linia crona
uruchomiona ręcznie), podgląd planu (`--plan`). **V3 = restore bezpieczny**,
osobna decyzja. Język interfejsu: polski, jak `alert-digest.sh`, z możliwością
przełączenia na angielski w jednym słowniku.

### P5. Zasięg: jeden host czy widok floty?

| wariant | za | przeciw |
|---|---|---|
| **jeden host (kolektor pokazuje swoje relacje i repliki)** | wszystko, co GUI czyta, jest lokalnie; brak nowych kanałów | operator z kilkoma kolektorami otwiera kilka tuneli |
| widok floty przez istniejący kanał SSH (kolektor odpytuje peerów `zfs-backup.sh status --json` po ssh) | jeden ekran na całą estatę | wymaga zaufania kolektor→peer w kierunku, który dziś istnieje tylko dla części relacji; opóźnienia; peer niedostępny musi być stanem, nie błędem |
| centralny agregator (nowy demon zbierający JSON z hostów) | najwygodniej | nowy komponent, nowy kanał, nowa powierzchnia — poza zakresem cienkiego GUI |

**[propozycja] V1 = jeden host.** Agregacja floty jako V2b, wyłącznie przez
`--json` po istniejącym kanale SSH, bez nowego demona i bez nowego zaufania:
kolektor pokazuje peera tylko, jeśli już ma do niego kanał root-ssh z
parowania; inaczej pokazuje go jako `nieosiągalny z tego hosta`, nie prosi o
klucz.

## 5. Etapy — co powstaje po odpowiedziach, i jaki dowód każdy niesie

| etap | zawartość | dowód przed scaleniem | wymaga właściciela |
|---|---|---|---|
| **A. dopełnienie JSON** | `status --json`, `relations --json`, `monitor --json` (orkiestracja nad zamrożonym monitorem); ten sam kształt co `progress --json`; kontrakt `json-shape` w `test/deps.conf` | suita z kontrolą ujemną per pole; `./test/impact.sh --verify`; CI | tylko „Scal" |
| **B. front do odczytu** | jeden plik, serwer na localhost, strona z odświeżaniem; testy: proces uruchomiony na stubach, odpowiedzi HTTP porównane z `--json` | suita `test/ui` na stubach; kontrola ujemna: zepsuty JSON → strona pokazuje błąd źródła, nie pustą tabelę | „Scal"; jeden przebieg na pve9 przez tunel (odczyt, bez runbooka) |
| **C. akcje bezpieczne** | allow-lista czasowników, każdy = jedno wywołanie CLI, wynik i kod wyjścia pokazane dosłownie | suita: każda akcja woła dokładnie tę komendę (stub rejestruje argv); kontrola ujemna: czasownik spoza listy → 403 | „Scal" + runbook na labie (pauza/wznowienie/uruchom teraz na parze pve9→pve10) |
| **D. widok floty** (jeśli P5 = tak) | odpyt peerów po ssh z limitem czasu; peer niedostępny = stan | suita na stubie ssh; kontrola ujemna: peer bez kanału → `nieosiągalny`, zero prób klucza | „Scal" + jeden przebieg na labie |
| **E. restore bezpieczny** | osobny dokument decyzji, jak ten | — | osobna decyzja |

Kolejność A→B→C jest wymuszona przez §2 pkt 1 (bez JSON nie ma widoku) i
pkt 2 (bez widoku stanu nie ma sensownej akcji). D i E są niezależne od siebie.

## 6. Wycena

Skalibrowana tempem repozytorium z `PYTHON-TRANSLATION-ESTIMATE-2026-09-03.md`
(~1657 linii i ~59 asercji dziennie w 53 dniach roboczych), nie stawkami z
podręcznika (błąd E35). Dni = dni implementera przy protokole „Scal" bez
dyskusji projektowych w środku etapu.

| etap | dni | uwaga |
|---|---|---|
| A. JSON | 2–3 | głównie testy kontraktu; kod to pakowanie istniejących odczytów |
| B. odczyt | 3–4 | najwięcej w stronie i w suicie na stubach |
| C. akcje | 3–5 | górna granica to runbook i poprawki po labie |
| D. flota | 2–3 | tylko jeśli P5 = tak |
| **razem A–C** | **8–12** | |

Odstępstwa od rekomendacji: TUI zamiast web obniża B o ~1 dzień i podnosi
C o ~1 (brak modelu żądań); port na LAN z hasłem dodaje 3–5 dni i nowy
rozdział bezpieczeństwa; wtyczka Proxmoxa — nie wyceniam, bo nie rekomenduję.

## 7. Otwarte — do słowa właściciela

Pięć odpowiedzi, po jednym zdaniu. Przy braku odpowiedzi implementer
przyjmuje rekomendację z §4 i mówi o tym w PR etapu A.

1. **P1 rodzaj:** web / TUI / wtyczka Proxmoxa. Rekomendacja: **web**.
2. **P2 miejsce i dostęp:** localhost + tunel SSH / port na LAN z hasłem /
   za `pveproxy`; proces jako root z allow-listą czasowników. Rekomendacja:
   **localhost + tunel, root, allow-lista**.
3. **P3 język:** Python 3 stdlib / bash+whiptail / inny. Rekomendacja:
   **Python 3 stdlib, jeden plik, bez pip**. Do potwierdzenia na pve9:
   `python3 --version`.
4. **P4 zakres V1:** tylko odczyt / + akcje bezpieczne / + restore.
   Rekomendacja: **tylko odczyt**, akcje jako V2, restore jako osobna decyzja.
5. **P5 zasięg:** jeden host / flota po istniejącym ssh / agregator.
   Rekomendacja: **jeden host**, flota jako V2b bez nowego zaufania.

Etap A z §5 nie zależy od żadnej z pięciu odpowiedzi i może ruszyć na
„Bierz A" bez czekania na resztę.
