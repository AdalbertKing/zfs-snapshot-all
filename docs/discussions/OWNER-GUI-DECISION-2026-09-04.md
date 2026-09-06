# Decyzja: cienkie GUI nad zfs-snapshot-all

Status: **ROZSTRZYGNIĘTE co do rodzaju i zakresu** (właściciel, 2026-09-05
i 2026-09-06). Dokument powstał 2026-09-04 jako pięć pytań z rekomendacją;
właściciel odpowiedział na wszystkie, jedną rekomendację obalił i przy okazji
wykazał błąd implementera w opisie tego, co pakiet umie zmieniać. Sekcje §5
i §4 są przepisane, nie dopisane. Otwarte pozycje są w §9. Żadna linia kodu
GUI nie powstała; ten dokument ma wyprzedzić pierwszą.

## 1. Co repozytorium już o GUI powiedziało

Wątki o GUI w repozytorium dotyczyły **kontraktu danych**, nie formy.

**[decyzja, 2026-08-23] Warstwa danych dla maszyn, nie tylko oczu.** Rekord
postępu niesie relację (`label`), tryb i bazę wyprowadzone z prawdziwej komendy
send (`full`/`incremental`/`resume`), tożsamość zadania i bajty na łączu
(`wire_bytes`, `-1` = niemierzalne), „żeby przyszłe GUI albo monitor mogły to
zbadać bez skrobania tekstu” (`docs/PROJECT_STATUS.md`).

**[decyzja, w kodzie] `--json` jest produktem, nie wygodą.** `progress --json`
i `list-replicas --json` mają ten sam kształt odpowiedzi, „so a front end learns
the convention once” (`zfs-backup.sh`, `cmd_list_replicas`). Stan nośnika jest
**pytaniem do bramki**, nie wnioskiem z listy pul, bo tylko bramka odróżnia
„pula niezaimportowana” od „w slocie jest ZŁY dysk”.

**[decyzja, 2026-09-01] Spójność nazw pod GUI.** „Pilnujemy spójności pakietu na
każdym etapie. To ma wejść pod GUI. Nie ma miejsca na chaos.” Stąd reguła
gramatyki list w `docs/project/FOUNDATIONS.md`.

**[decyzja, 2026-09-01] Część wsadowa zamknięta**, „kolejny etap jest po stronie
GUI, nie wsadu” (`docs/project/OWNER-DECISIONS.md`).

**[dyskusja, 2026-08-17] „GUI dostaje jeden czasownik na relację.”**
`ZFSBACKUP-ONLY-DEPLOYMENT` §3 zauważa też, że jednodotykowość **nie** zwiększa
świadomości klikającego operatora, więc GUI nie może być argumentem za
osłabieniem odmów.

## 2. Zasady

Pierwsze osiem obowiązuje przy każdym wariancie i nie są do dyskusji, bo
wynikają z zasad, które pakiet już ma. Cztery ostatnie doszły z decyzji o
terminalu (§5 P1) i są **wymaganiami kontraktu, nie uwagami**.

1. **GUI nie skrobie tekstu.** Czyta `--json` i pliki stanu o ustalonym
   kształcie. Czego nie ma w JSON, to najpierw dochodzi w CLI (§7 etap A).
2. **GUI nie omija odmów.** Każda akcja to istniejąca, udokumentowana ścieżka
   produktu z jej bramkami. GUI nie ma własnej kopii żadnej reguły
   bezpieczeństwa i nie ma trybu „na siłę”.
3. **GUI nie dotyka zamrożonych silników** (`snapsend.sh`, `snapget.sh`,
   `delsnaps.sh`, `check-snap-age.sh`, `lib-zfs-snap.sh`).
4. **Jeden czasownik na relację.** Widok relacji pokazuje dokładnie te akcje,
   które CLI dopuszcza dla tego stanu. Żadnych kreatorów składających kilka
   czasowników w jedno kliknięcie bez pokazania, co się wykona.
5. **Restore poza pierwszym zakresem.** Wchodzi jako osobny etap po labie i
   tylko w formie bezpiecznej; destrukcyjny zostaje w CLI do odrębnej decyzji.
6. **Bez nowej powierzchni ataku.** Brak gniazda nasłuchującego, brak nowego
   mechanizmu uwierzytelniania (§5 P2).
7. **Bez nowych zależności na hoście** poza tym, co §5 P3 jawnie dopuszcza.
8. **Ta sama dyscyplina testowa.** Kontrakty JSON dostają suitę z kontrolą
   ujemną, widoki testy na stubach, akcje obowiązek runbooka na labie.
9. **Terminal jest celem, nie wariantem awaryjnym.** 80 kolumn to przypadek
   projektowy: układ ma się w nich mieścić, a przy 120 i 200 wykorzystywać
   miejsce. Nie wolno projektować na szerokość i „obcinać na wąskim”.
10. **Ramki mają wariant ASCII**, gdy terminal nie jest w UTF-8, a werdykty
    niosą **słowa** (`OK`, `WARNING`, `CRITICAL`, `UNKNOWN`), nie tylko kolor.
    Cztery werdykty muszą być rozróżnialne przy 16 kolorach i przy zerze.
11. **Odświeżanie maluje różnice, nie ekran.** Admin łączy się z domu przez
    VPN; `curses` wysyła zmienione komórki, co przy sekundowym odświeżaniu
    listy transferów daje setki bajtów, nie kilkanaście kilobajtów.
12. **Zapis idzie udokumentowaną ścieżką produktu i pokazuje komendę** przed
    wykonaniem (§4).

## 3. Inwentarz warstwy danych

Zmierzone 2026-09-04 na `main` `6c5c01d`.

| dana | źródło dziś | pod GUI |
|---|---|---|
| postęp transferów | `progress --json` (`relations[]`, `jobs[]`, `dataset`, `target`, `label`, `state`, `done_bytes`, `total_bytes`, `updated_epoch`) | **gotowe** |
| repliki i nośniki | `list-replicas --json`, stan nośnika z bramki | **gotowe** |
| rekordy postępu | `/var/lib/zfs-snapshot-all/progress/<klucz>.json` | gotowe |
| historia biegów | log statystyk, JSON-lines (`mode`, `base`, `duration_s`, `rate_bps`, `wire_bytes`, `status`) | gotowe |
| stan relacji | `status [NAZWA]` — **tylko tekst** | **brakuje `--json`** |
| lista relacji | brak czasownika listującego maszynowo | **brakuje** |
| wiek snapshotów | `check-snap-age.sh`, kontrakt 0/1/2/3, tekst; **zamrożony** | JSON w warstwie orkiestracji, nie w silniku |
| pauza / hold | pliki stanu w `/var/lib/zfs-snapshot-all/relationships`, `/root/.zfs-snapshot-all-*-state` | odczyt z plików |

Wniosek bez zmian: przed pierwszym widokiem potrzebne są `status --json`,
`relations --json` i `monitor --json` w warstwie orkiestracji. To etap A (§7)
i nie zależy od żadnej decyzji.

## 4. Ścieżka zmiany konfiguracji — zmierzone 2026-09-06

Sekcja powstała, bo implementer napisał właścicielowi, że retencji i
harmonogramu „nie da się zmienić na istniejącej relacji”. To było fałszywe.
Zapis błędu: E38 w `docs/internal/IMPLEMENTER-ERROR-LOG.md`.

**Warstwą sterowania jest CONFIG, nie zbiór czasowników.**
`docs/CONFIG-EXAMPLES.md` mówi wprost: *„after install the config is the
execution truth, and hand-writing or hand-editing one is a supported,
first-class path — the documentation, not the CLI, is the escape hatch for
bespoke policy.”* `gen-cron.sh` czyta jeden config INI (v4) na host i generuje
z niego zarządzany blok crontaba.

Trzy osie, każda ma inną drogę:

| oś | co obejmuje | droga zmiany |
|---|---|---|
| **polityka** | retencja i GFS, harmonogramy send i prune, quiesce, wykluczenia, rekursja, progi monitora | edycja configu → `gen-cron.sh -c FILE` (render na stdout, niezerowy kod przy błędzie) → `gen-cron.sh -c FILE --install` (idempotentna podmiana bloku) |
| **zakres** | które datasety relacja replikuje | zwężenie: sama edycja configu. Poszerzenie: **dodatkowo** `--commit-scope` po stronie źródła, bo dowodem zakresu jest plik scope z sygnaturą sha256, której kolektor nie napisze (`rux_verify_requested_scope`) |
| **tożsamość i łącze** | endpoint, pasmo, profil, pauza, blokada u peera | osobne czasowniki: `set-endpoint`, `set-bandwidth`, `migrate-profile`, `pause-client`/`resume-client`, `enable-client`/`disable-client` |

`gen-cron.sh --reconcile` porównuje w trybie tylko do odczytu, co config
kopiuje, z tym, co naprawdę istnieje. **Usunięcie relacji i założenie jej od
nowa nie jest ścieżką zmiany konfiguracji** i nie wolno jej tak przedstawiać
w GUI.

**Tworzenie** ma własną, bogatą ścieżkę, której implementer początkowo nie
wymienił: dispatcher kieruje `--source=` i `--target=` do `rux_entry`, formy
jednokomendowej, która paruje, robi join, opcjonalnie zatwierdza zakres na
źródle (`--grant-remotely`), seeduje i aktywuje. `--source` niesie listę
datasetów, `--source=HOST:` bierze cały host, `--mode=sync` odtwarza ścieżki
źródła. Ponowne uruchomienie z **tymi samymi** parametrami przechodzi przez
`rux_check_conflict`, więc relację zatrzymaną w połowie cyklu można dokończyć;
z **innym** zakresem, celem lub trybem ta sama kontrola odmawia.

## 5. Pięć pytań — rozstrzygnięte

### P1. Rodzaj — **TUI, tryb tekstowy pełnoekranowy**

Decyzja właściciela 2026-09-05: *„To serwer backupu. Często dostępny dla admina
po SSH… Admin łączy się z domu przez VPN i putty z kolektorem. Ma tylko tekst.”*
Rekomendacja implementera brzmiała „przeglądarka” i była błędna: uzasadniała ją
dostępność z dowolnego miejsca, a pomijała, że operator **jest już** w sesji SSH
na kolektorze. Web kazałby mu uruchomić proces, zestawić tunel, przejść do
przeglądarki i wrócić. Wtyczka Proxmoxa odpada jak poprzednio (wiązałaby pakiet
z wewnętrznym API `pve-manager`).

### P2. Miejsce i dostęp — **pytanie znika**

Brak procesu nasłuchującego, brak portu, brak tunelu, brak własnych haseł.
Uwierzytelnia SSH, które już istnieje, a proces widzi dokładnie to, co konto,
które go uruchomiło — zgodnie z modelem delegacji pakietu. Znika też
interakcja z `update-hold` i self-update, bo nie ma demona do restartu.

### P3. Język — **Python 3 z biblioteki standardowej, `curses`**

Zero nowych pakietów na hoście, ta sama warstwa JSON co przy odrzuconym
wariancie web. Wygląd w idiomie **Turbo Vision** (pasek menu, okna z ramką i
cieniem, listwa F-klawiszy), bo to znaki, nie framework.

`magiblot/tvision` (żywy port, C++17, Unicode, 24-bit kolor, konsola Windows)
daje autentyczny CUA z nakładającymi się oknami i myszą, ale wciąga do pakietu
kompilowany artefakt i łańcuch budowania, a `deploy.sh` dziś kopiuje pliki z
gita. **Odrzucone, chyba że właściciel zechce nakładających się okien i myszy
na tyle, żeby przyjąć kompilowany komponent.**

### P4. Zakres — **zarządzanie, nie tylko odczyt** (zmienione)

Decyzja właściciela 2026-09-06. Ekran główny listuje relacje kolektora ze
stanem; focus na wierszu pokazuje szczegóły w dolnej części okna; Enter wchodzi
w ustawienia; z ekranu głównego da się dodać, usunąć, wstrzymać i modyfikować.
Rekomendacja implementera brzmiała „tylko odczyt” i została zmieniona przez
właściciela. Zasady §2 pkt 2, 4 i 12 obowiązują bez zmian: każda akcja to
udokumentowana ścieżka produktu z pokazaną komendą.

### P5. Zasięg — **jeden host**

Bez zmian. TUI to wzmacnia: admin loguje się na ten kolektor, który go
interesuje. Agregacja floty tylko po istniejącym kanale SSH i tylko wtedy, gdy
pojawi się realna potrzeba (plan: „conveniences backed by a real need”).

## 6. Ekrany

| ekran | treść | akcje |
|---|---|---|
| **Główny** | lista relacji: nazwa, stan, werdykt monitora, ostatni wynik, następny bieg. Pod listą panel szczegółów dla wiersza z focusem: datasety, cel, spójność, ostatni bieg z logu statystyk, następny, monitor, alerty, ostrzeżenia | `Ins` nowa, `Del` usuń, `F4` pauza/wznów, `Enter` ustawienia, `F3` log |
| **Ustawienia relacji** | strukturalny edytor sekcji configu należących do tej relacji (wskazują je `MANAGED_DATASETS` i `MANAGED_PRUNE_SCOPE` z rekordu), plus pola z własnymi czasownikami | Zapisz = render jako podgląd, diff wobec zainstalowanego bloku, `--install`. Edycja poszerzająca zakres odmawia i nazywa `--commit-scope` na źródle |
| **Nowa relacja** | kreator odwzorowujący formę jednokomendową `--source=/--target=`; `--grant-remotely` i `--join-remotely` jako pola wyboru; „Dokończ” dla relacji zatrzymanej w połowie cyklu | pokazuje pełną komendę przed wykonaniem |
| **Transfery** | postęp na żywo, tryb i baza, bajty na łączu, zatrzymana aktualizacja | — |
| **Monitor** | linie monitora z czterema werdyktami i powodem | — |
| **Nośniki** | repliki i cztery stany nośnika | — |

Nawigacja: `F2`–`F6` przełączają ekrany, `Enter` otwiera okno na wierzchu,
`Esc` zamyka. Panel obok listy zamiast pod nią dopiero od ~120 kolumn.
Zmierzone: ekran główny z panelem mieści się w 20 z 24 wierszy przy 80
kolumnach.

## 7. Etapy

| etap | zawartość | dowód przed scaleniem | wymaga właściciela |
|---|---|---|---|
| **A. dopełnienie JSON** | `status --json`, `relations --json`, `monitor --json`; ten sam kształt co `progress --json`; kontrakt w `test/deps.conf` | suita z kontrolą ujemną per pole; `--verify`; CI | tylko „Scal” |
| **B. ekran główny + panel** | odczyt, lista i szczegóły, bez akcji | suita `test/ui` na stubach; kontrola ujemna: zepsuty JSON → strona mówi „błąd źródła”, nie pusta tabela; render przy 80, 120 i 200 kolumnach, w UTF-8 i ASCII | „Scal”; jeden przebieg na pve9 przez PuTTY |
| **C. akcje bez zapisu configu** | pauza, wznowienie, dokończenie relacji, `F3` log | suita: każda akcja woła dokładnie tę komendę (stub rejestruje argv) | „Scal” + runbook na labie |
| **D. ekran ustawień** | edytor configu z podglądem, diffem i `--install`; odmowa przy poszerzeniu zakresu | suita: edycja → render → diff; kontrola ujemna: config po edycji nie przechodzi walidacji `gen-cron` i `--install` się nie wykonuje | „Scal” + runbook na labie |
| **E. kreator nowej relacji** | forma jednokomendowa | suita na stubach + pełny przebieg na parze labowej | „Scal” + lab |
| **F. restore** | osobny dokument decyzji | — | osobna decyzja |

## 8. Wycena

Skalibrowana tempem repozytorium z `PYTHON-TRANSLATION-ESTIMATE-2026-09-03.md`
(~1657 linii i ~59 asercji dziennie w 53 dniach roboczych), nie stawkami z
podręcznika (błąd E35).

| etap | dni |
|---|---|
| A. JSON | 2–3 |
| B. ekran główny + panel | 3–4 |
| C. akcje bez zapisu | 2–3 |
| D. ekran ustawień | 4–6 |
| E. kreator | 3–5 |
| **razem A–E** | **14–21** |

Etap D i E są droższe niż odczyt, bo obie ścieżki zapisu mają runbook na labie,
a kreator odwzorowuje formę jednokomendową z jej wzajemnymi wykluczeniami.

## 9. Otwarte

1. **`python3 --version` na pve9** i pozostałych hostach floty. Jedyna rzecz,
   która może obalić P3. Jeśli python3 nie ma, decyzja wraca do dyskusji.
2. **Czy nakładające się okna i mysz są warte kompilowanego komponentu**
   (`magiblot/tvision`) zamiast `curses`. Domyślnie nie.
3. **Kiedy ruszamy** i od którego etapu. Etap A nie zależy od nic i może ruszyć
   na słowo właściciela.
