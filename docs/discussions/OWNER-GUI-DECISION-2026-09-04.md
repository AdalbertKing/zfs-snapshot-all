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

Powyższe trzy osie dotyczą **relacji**. Replika nie jest żadną z nich i nie
jest relacją — patrz §4a.

## 4a. Replika to konfiguracja KOLEKTORA

Właściciel, 2026-09-06: *„Replika jest konfiguracją kolektora. Nie relacji.
Kolektor może mieć kilka replik, ale to wciąż konfiguracja kolektora.”*
Repozytorium zapisało to już przy labie replik, w tabeli wad: *„replika to inny
RODZAJ zadania (bez monitora, bez prune źródła, **bez relacji**), a nie drugi
`dst`”* (R1, `docs/PROJECT_STATUS.md`). Implementer zaprojektował dwie wersje
tego dokumentu, zanim to znalazł.

Konsekwencje dla architektury informacji:

- Replika nie ma peera, parowania, grantu ani endpointu. Bierze dataset, który
  **jest tutaj**, i kopiuje go na inną pulę **tutaj**, zwykle na nośnik
  wymienny. Cała rzecz jest własnością tej jednej maszyny.
- Mieszka w `[replica:NAZWA]`, szóstym rodzaju sekcji, którego `usage` samego
  `gen-cron.sh` nie wymienia (zmierzone 2026-09-06: zero wystąpień, choć
  `_allow_fields replica` i `build_replica_section` istnieją). Pola: `source`,
  `dst`, `schedule`, `prefix`, `notify`, `media`, `recursive`, `flags`,
  `history`.
- Jedno źródło może mieć **kilka** replik; lab z 2026-08-29 postawił **trzy
  sekcje `[replica:]` na jednym źródle**, każdy nośnik z własną kotwicą.
- Edycja już istnieje: `add-replica` jest **upsertem** (to samo polecenie
  zakłada i zmienia), `remove-replica` usuwa, `run-replicas` uruchamia,
  `purge-replica-copy` kasuje dane na nośniku.

**Wejście do tego jest z menu głównego, nie z listy relacji** (§6, ekran
Kolektor). Replika stoi obok innych ustawień tej maszyny, a nie obok relacji
z innymi maszynami.

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
| **Nośniki** (status) | repliki i cztery stany nośnika — widok monitorujący, nie konfiguracyjny | `Enter` skacze do konfiguracji tej repliki na ekranie Kolektor |
| **Kolektor** (z menu, nie z F-klawisza) | konfiguracja **tej maszyny**: repliki (`[replica:]`), wyzwalacz udev, `[defaults]` (`host_label`, `repo_dir`, `notify_script`, `warn_script`, `digest_script`, `cron_log`), `server.conf` (`DEFAULT_TARGET`, `CRON_CONFIG`), kopie lokalne | replika: `Ins` nowa, `Enter` edycja (oba na upsert `add-replica`), `Del` `remove-replica`, `F5` `run-replicas`; wyzwalacz: `install-media-trigger`/`remove-media-trigger`. `purge-replica-copy` **poza V1**: kasuje dane na nośniku, klasa destrukcyjna razem z restore |

Makiety w docelowym medium: `gui-mockups/tui/`. Wariant przeglądarkowy,
odrzucony 2026-09-05, leży w `gui-mockups/web-odrzucony/` — zachowany za
architekturę informacji, nie jako propozycja.

Ekran ustawień zakłada czasownik zmiany polityki, zlecony osobno:
`OWNER-CONFIG-VERBS-2026-09-06.md`. Bez niego TUI musiałoby samo edytować INI,
czyli nosić drugą kopię schematu pól, wbrew §2 pkt 2. Z czasownikiem etap D
spada z 4–6 dni do 2–3.

Podział jest celowy: `F2`–`F6` to **relacje i ich stan**, czyli to, co ta
maszyna robi z innymi maszynami; menu `Kolektor` to **ustawienia tej maszyny**.
Replika należy do drugiej grupy.

Nawigacja: `F2`–`F6` przełączają ekrany, `Enter` otwiera okno na wierzchu,
`Esc` zamyka. Panel obok listy zamiast pod nią dopiero od ~120 kolumn.
Zmierzone: ekran główny z panelem mieści się w 20 z 24 wierszy przy 80
kolumnach.

## 6a. Okno relacji i edytor polityki — najtrudniejsze okno

Właściciel, 2026-09-07: *„Skupmy się na tym, co się dzieje po wejściu w
tworzenie / modyfikacje relacji. To najtrudniejsze okno. […] Przyznaję, że nie
mam pomysłu."* Poniżej jest pomysł, wyprowadzony z pól, a nie z wyobrażenia o
formularzu.

### Trzy obiekty, nie jeden formularz

Zmierzone w `gen-cron.sh`: **każde** pole polityki — `gfs`, `keep`, `retain`,
`quiesce`, `send_schedule`, `prune_schedule`, `prefix`, `monitor_warn/crit` —
należy do `[template:<szczebel>]` (`POLICY_FIELDS`, `gen-cron.sh:1329`). Do
relacji należą pola zupełnie inne: `use_template`, `pair_label`, pola ŁĄCZA
(`bandwidth`, `compression`, `cipher`) i pola ZAKRESU (`passive`,
`exclude_family`, `exclude_child_<n>`) — świadomie poza `POLICY_FIELDS`, bo
nośnik polityki jest współdzielony przez datasety, które nie dzielą celu.

Stąd podział, który czyni to okno projektowalnym:

| obiekt | co niesie | gdzie |
|---|---|---|
| **relacja** | zakres, łącze, pauza, **którą polityką** | okno relacji |
| **polityka** (profil) | szczeble: kadencja, ile, mechanizm, quiesce, progi | osobny edytor, wołany z relacji |
| **wiązanie** | który dataset bierze które szczeble | macierz w oknie relacji |

W oknie relacji retencji **nie ma** — jest nazwa polityki i dwa przyciski.
Powód nie jest estetyczny: profil jest współdzielony, a edycja go „od środka
jednej relacji" sugerowałaby zasięg, którego ten obiekt nie ma. Profile
fabryczne są przy tym plikami pakietu, więc się ich nie edytuje, tylko
**klonuje** — a namespace `profile__<nazwa>__<szczebel>` (`lib-profile.sh`) już
dokładnie to obsługuje.

### Wiązanie: macierz dataset × szczebel

`gui-mockups/tui/relacja-polityka-macierz-80.txt` — czternaście datasets,
cztery szczeble. Jedna komórka to jeden człon listy `use_template`.

Sześć decyzji, które sprawiają, że czternaście wierszy jest czytelne:

1. **Ścieżka skrócona o wspólny przedrostek** — nagłówek niesie `rpool/data/…`,
   wiersze tylko liść. Dwa rozłączne korzenie = dwa nagłówki-separatory.
2. **`≠` przy wierszu różnym od domyślnej.** W liście identycznych krzyżyków
   oko nie znajdzie dwóch wyjątków, a to one są tym, co trzeba zobaczyć po
   tygodniu. Znacznik zastępuje kolor (§2 pkt 3); klawisz `=` przywraca wiersz.
3. **`!` i „bez zadania" dla wiersza z samymi pustymi polami.** Realny cichy
   stan: dataset jest w zakresie, ale bez `use_template` nie powstanie dla
   niego ani jedna linia crona. Dziś widać to dopiero po nieobecności zadania.
4. **Wiersz domyślnej wpisany w siatkę**, a jego zmiana omija wiersze z `≠` —
   inaczej jedno naciśnięcie kasowałoby wyjątki, których ktoś bronił.
5. **Rekurencja zwija dzieci** (`recursive = yes` → `(+ dzieci)`), bo dzieci nie
   mają własnych sekcji; bez tego jedna relacja rozwinęłaby listę do stu
   pozycji opisujących jedną decyzję.
6. **Operacje masowe z nagłówka i z filtru**: `Spacja` pole, `^Spacja` kolumna,
   `*` wiersz, `/` filtr — po filtrze operacje masowe działają na
   przefiltrowanym zbiorze.

Twardy przypadek to nie liczba datasets, tylko profil o pięciu szczeblach z
nazwami, które nie skracają się do jednej litery — `Y5M12D31H24` ma
`solo_hourly`, `keep_hourly`, `keep_daily`, `keep_monthly`, `keep_yearly`, a
dwie zaczynają się tak samo. Wtedy kolumny są **numerowane**, legenda stoi nad
siatką, a cyfra staje się klawiszem
(`relacja-polityka-macierz-5szczebli-80.txt`). Granica formy to około ośmiu
szczebli; najdłuższy profil w drzewie ma pięć, więc więcej jest hipotezą, nie
przypadkiem projektowym.

**Budżet wierszy, powiedziany wprost:** okno macierzy ma 24 wiersze razem z
ramką, czyli przy terminalu 80×24 wypełnia ekran w całości i pokazuje 10 z 14
datasets. Na wyższym terminalu rośnie lista, nie ramka.

### Edytor polityki: siatka szczebli, nie formularz

`gui-mockups/tui/edytor-polityki-80.txt`. Radiobutton mechanizmu i checkbox
quiesce żyją **w wierszu szczebla**, nie w dialogu: `gfs` i `quiesce` to pola
`[template:]`, więc jeden przełącznik nad całym oknem sugerowałby własność
profilu, której nie ma. Cztery rozstrzygnięcia:

1. **„Ile" zmienia jednostkę razem z mechanizmem.** FLAT i GFS piszą
   `keep = 24`, AGE pisze `retain = -h24`. Pasek pod siatką tłumaczy komórkę z
   focusem na konsekwencję — „24 najnowsze" / „po jednej na godzinę przez 24 h"
   / „wszystko młodsze niż 24 h". To jedyne miejsce, gdzie GUI może uprzedzić
   awarię zmierzoną na pve10: `-G -H24 -D7` zostawiło **0 z 6** migawek z
   `rc=0` i bez ostrzeżenia.
2. **Kształt (jedna rodzina vs rodzina na szczebel) stoi nad siatką**, bo
   zmienia znaczenie wiersza. Przy jednej rodzinie quiesce nie może być per
   szczebel — dzienna migawka JEST jedną z godzinnych — więc kolumna szarzeje.
3. **Nazwa jest wyprowadzana z siatki, nie wpisywana.** `profiles/README.md`
   mówi „nazwa to retencja", a `test/profiles` to egzekwuje przeciw
   wyrenderowanej linii `delsnaps`. Pole tekstowe pozwoliłoby nazwać `d7h24`
   coś, co trzyma 30 dni. Człowiek wpisuje tylko `description`.
4. **Profil fabryczny otwiera się tylko do odczytu**, `F2` to „Zapisz jako…".

### Retencja niesymetryczna: istnieje i ma twardą regułę

`--source-profile=NAME` (`zfs-backup.sh:223`) daje stronie źródłowej własną
retencję; namespace `src_` powstał po REV-20260811-104 F1 właśnie po to, żeby
edycja jednej strony nie ruszała drugiej. Trzy fakty muszą trafić do okna
(`relacja-polityka-retencja-80.txt`):

1. **Pominięcie flagi znaczy „ten sam profil po obu stronach", nigdy
   „domyślny na źródle"** — fallback do `default` po cichu zmieniłby retencję
   każdej relacji założonej bez tej flagi.
2. **Wolno różnić się ILOŚCIĄ, nie wolno RODZAJEM.**
   `assert_source_profile_families` porównuje zbiór rodzin, gdzie rodzina to
   `pattern` **plus sposób liczenia** (`gfs`). `d7h24-gfs` pod
   `m12w4d7h24-gfs` przechodzi; `d7h24` (płaski) pod `d7h24-gfs` (drabina) jest
   odmawiane, bo prune wycelowany w rodzinę, której relacja nie tworzy, nie
   trafia w nic — a `delsnaps`, który nic nie dopasował, kończy się zerem.
   Źródło trzymałoby wszystko, raportując sukces co noc.
   **Konsekwencja dla GUI: listę filtrujemy, nie pokazujemy błędu po fakcie** —
   z liczbą i powodem ukrycia, bo lista gubiąca 14 z 16 pozycji bez słowa
   wygląda na zepsutą.
3. **Ręcznie zredagowana retencja źródła to stan pierwszej klasy** —
   re-aktywacja świadomie ją zachowuje (REV-20260811-107), więc okno mówi „nie
   odpowiada żadnemu profilowi" zamiast po cichu podstawić katalogowy.

### Wykluczenia: cztery mechanizmy, trzech właścicieli

`relacja-zakres-wykluczenia-80.txt`. Zmierzone: `exclude`/`exclude_tree` w
pliku zakresu (`lib-scope.sh:35`), `exclude_child_<n>` → `-X` i
`exclude_family` → `-E` w `[dataset:]` (`gen-cron.sh:117-122`),
`[excluded:<prefix>] keep` → `-P` (`gen-cron.sh:338`).

| co wykluczasz | czym | kto decyduje |
|---|---|---|
| dataset, którego relacja nie ma prawa zabrać | `exclude` / `exclude_tree` w pliku zakresu | **źródło** — podpis sha256, poszerzenie tylko przez `--commit-scope` tam |
| dataset, którego kolektor sam nie chce | `exclude_child_<n>` (regex, `-X`) | **ta relacja** |
| rodzinę migawek, której nie adoptujesz | `exclude_family` (`-E`) | **ta relacja**, tylko w trybie pasywnym |
| cudzą rodzinę, której prune nie kasuje | `[excluded:prefix] keep=N\|all` (`-P`) | **kolektor**, dla całego configu |

Dwa ostatnie wiersze są maskami migawek i **idą w przeciwne strony**: `-E` mówi
„nie bierz tego, co widzę na źródle", `-P` mówi „nie kasuj tego, co jest
cudze". Jedno pole „wykluczenia snapshotów" byłoby spłaszczeniem wbrew §2
pkt 2, a kosztem pomyłki jest skasowanie migawki `__replicate_` spod `pvesr`,
czyli nieodwracalne zerwanie łańcucha replikacji.

Cztery rozstrzygnięcia ekranu zakresu:

1. **Sekcja źródła jest tylko do odczytu i tak wygląda** — to nie ograniczenie
   GUI, tylko granica własności.
2. **Wzorzec pokazuje SKUTEK, nie tylko siebie**: „pomija 3 z 14" plus nazwy.
   Regex bez rozwinięcia to obietnica, nie fakt.
3. **Numeracja `exclude_child_1..n` nie wychodzi na ekran.** Pole jest
   numerowane od jedynki bez dziur, a `gen-cron` odmawia przy dziurze, bo wpisy
   powyżej są po cichu gubione — to zadanie pisarza, nie operatora.
4. **Sekcja `exclude_family` szarzeje poza trybem pasywnym**, a `[excluded:]`
   jest tylko skrótem do ekranu Kolektor, bo obowiązuje całą maszynę.

### Czego to okno nie robi

Nie powtarza ani jednej reguły. `F9 Podgląd` renderuje kandydata przez
**prawdziwy `gen-cron.sh -c PLIK`** i pokazuje odmowę dosłownie; `Zapisz` jest
zablokowany do czasu czystego renderu. To wzorzec `cmd_set_bandwidth`: kopia
robocza → edycja → walidacja renderem → odmowa z nietkniętym oryginałem. Za
darmo dostajemy m.in. odmowę progu monitora nie dłuższego niż faktyczna
kadencja (gen-cron chodzi po prawdziwym kalendarzu: tygodniowa to 7 dni,
pon.–pt. to 72 godziny), odmowę monitora na zakresie zdalnym i kolizje
prefiksów — bez linii logiki w TUI.

**Tworzenie to kreator, modyfikacja to zakładki.** Tworzenie odwzorowuje
kolejność `rux_entry` (źródło → cel → zakres → polityka → seed → aktywacja),
bo ta kolejność coś znaczy: seed idzie przed cronem. Modyfikacja zmienia jedną
oś, więc kreator byłby tam tylko przeszkodą.

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
