# PROJECT_STATUS — faktyczny stan projektu

> **To jest dokument ŻYWY, nie protokół z jednego dnia.**
> Odświeżany przez implementera na końcu **każdego** etapu, zanim etap zostanie
> zgłoszony jako zrobiony. Jeżeli data poniżej jest starsza niż ostatni commit
> zmieniający zachowanie — dokument jest zepsuty i to jest defekt do zgłoszenia,
> nie drobiazg. Obowiązek jest zapisany w `CLAUDE.md` i przypomina o nim
> `./test/impact.sh` jako obowiązek ręczny `project-status`.

<!-- status-covers-digest: 6f67bf7d6bbb3f74 -->
<!-- Znacznik maszynowy: skrot TRESCI wszystkich plikow, ktore deklaruja
     obowiazek project-status. Zapisywany przez ./test/impact.sh
     --refresh-status, sprawdzany przez --verify. Nie usuwac i nie zmieniac
     formatu -- to jedyne, co odroznia dokument aktualny od takiego, ktory
     tylko wyglada na aktualny.

     Byl tu wczesniej SHA ostatniego commita zmieniajacego zachowanie. Tego nie
     dalo sie sprawdzic PRZED tym commitem -- commit nie zawiera wlasnego
     skrotu -- wiec --verify uruchomiony jako bramka przed etapem raportowal
     czysto, a commit, ktory blogoslawil, ladowal nieswiezy (REV-20260807-068
     F1). Skrot tresci jest dowodliwy przed commitem i niezmieniony przez
     commit, wiec jeden przebieg dowodzi wlasnosci po obu stronach granicy. -->

- **Rekord to dane, `die` kończy program, stan wywołania zerowany na wejściu
  (2026-09-03, PR z gałęzi `claude/package-translation-estimate-jisaqu`).**
  Właściciel po oszacowaniu kosztu tłumaczenia pakietu na Pythona wybrał
  tańszą alternatywę: usunąć w bashu trzy klasy błędów, które były głównym
  argumentem za portem. Trzy logiczne commity, każdy z regresją dyskryminującą
  (kontrola ujemna na `main` uruchomiona przez `ZFSBACKUP=<worktree main>`).

  **1. Czytnik rekordów.** Każdy odczyt rekordu relacji, manifestu parowania i
  markera pauzy wykonywał plik przez `.` — 18 odczytów jednopolowych
  `$( . "$f"; printf "${POLE:-}" )`, 21 pełnych `. "$cpath"`/`. "$mpath"` i
  CZTERY ręczne kopie „wyczyść to, co ustawił poprzedni rekord, potem
  source" (`load_client_and_connection`, `migrate_read_record`,
  `cmd_set_bandwidth`, skan peerów w `remove-client`). `lib-backup-common.sh`
  ma teraz `record_get <plik> <POLE> [domyślne]` i `record_load <zbiór>
  <plik>`: żaden nie wykonuje pliku, wartości odcytowywane jak bash czytałby
  słowo (gołe, `\`, `'..'`, `".."`, `$'..'` — kształty `printf %q` i heredoca
  manifestu), `$VAR`/`` `cmd` ``/`$(cmd)` zostają LITERAŁEM. `record_load`
  zeruje (pustym łańcuchem, nie `unset` — wołający deklarują pola `local`)
  każde pole, które poprzedni odczyt do tego samego zbioru przypisał, odmawia
  pola nazwanego jak zmienna powłoki (`PATH=`) i zwraca 2 na pliku, który nie
  jest rekordem (niedomknięty cudzysłów, linia nie-`KLUCZ=`), więc ścieżka
  fail-closed z REV-084 w `coverage_conflicts` dalej strzela. Formaty na dysku
  nietknięte. Suita `zfsbackup` sekcja `records`: rekord z `$(touch ...)`
  listuje się w `status` i niczego nie uruchamia (na `main` PADA — plik jest
  wykonywany), `PATH=` odmówiony po nazwie (na `main` PADA), round-trip
  `%q`/heredoc w locale C i UTF-8, dwa rekordy w jednej powłoce bez
  dziedziczenia. Harnessy `test/rerun` i `test/linkfields` wycinają bloki
  programu do własnych skryptów, więc sourcują teraz tę samą bibliotekę co
  program.

  **2. `die` w `$( )`.** `die` z biblioteki to było `echo; exit 1` — poprawne
  w głównej powłoce i no-op za każdym `x=$(fn)`: kończyło podpowłokę,
  oddawało pusty łańcuch i program szedł dalej (F11 restore: trzy FATAL i
  exit 0). `zfs-restore.sh` miał od 2026-08-27 własne `die` z `kill -TERM`
  na pid głównej powłoki; mechanizm przeniesiony do biblioteki
  (`die_arm_fatal` wołane pod strażnikiem `BASH_SOURCE[0] == $0` obu
  programów, więc suita sourcująca program nie ginie i — jak dotąd — nie
  obserwuje tej własności). `zfs-backup.sh` ma 97 przypisań `x=$(fn)` i 80
  funkcji, które mogą dojść do `die`; audyt przechodni znalazł 8 miejsc
  obsługujących błąd podpowłoki — 7 doklejało drugie `die` lub `return 1` za
  pierwszym FATAL (teraz stają na pierwszym), jedno chce świadomie tylko
  podpowłoki: sonda peera w `cmd_status` (rekord bez manifestu = UNKNOWN,
  nie przerwanie widoku) i mówi to na miejscu przez
  `die_confine_to_subshell`. Bez globalnego przełącznika. Sekcja `fataldie`:
  `set-endpoint NAZWA --host='bad host'` wypisuje DOKŁADNIE jeden FATAL,
  exit 1, rekord nietknięty (na `main` PADA: drugi, niezwiązany FATAL
  „refusing to switch" po pierwszym); `status NAZWA` na rekordzie bez
  manifestu dalej raportuje.

  **3. Reset stanu wywołania.** `SRC_PROFILE_NAME` zerowane było dwiema
  kopiami tej samej linii (`add-client`, `local-backup`); `activate-client`,
  które bierze nazwę z REKORDU i tylko dla nowej relacji, nie miało żadnej —
  rekord bez `SOURCE_PROFILE` czytał to, co zostawiło poprzednie polecenie w
  tym samym procesie. Jedna funkcja `cmd_reset_invocation_state`, wołana jako
  pierwsza przez wszystkie trzy. Sekcja `invocation`: harness sadzi wartość
  „stale" i odczytuje ją w chwili, gdy polecenie pada na złych argumentach —
  `activate-client` na `main` zwraca „stale", pozostałe dwa pinują wspólną
  funkcję.

  **Zmierzone lokalnie (Linux, natywny bash).** Wszystkie suity z planu
  `impact.sh` dla zakresu: `zfsbackup` (4 błędy środowiska — `ssh-keygen -F`
  w kontenerze — identyczne na `main` tym samym przebiegiem), `localbackup`
  (14 identycznych błędów środowiska: proces roota z checkoutem poza
  `/root`), `restore` 300/300, `restoregrant` (3 identyczne na `main`: test
  wymaga konta nie-root), `rerun` 16/16, `linkfields` 49/49, `rux` 43/43,
  `stagger` 26/26, `moveclient` 41/41, `scopefields` 36/36. Zero nowych
  błędów względem `main` w tym samym środowisku. Pełną baterię rozstrzyga
  CI.

  **Świadomie NIE ruszone:** `read_server_conf` (nadal `.`-sourcuje
  `SERVER_CONF`; ma udokumentowany powód, żeby nie zerować cudzych pól, więc
  nie pasuje do `record_load` bez osobnej decyzji), `deploy.sh`
  (`. "$mpath"`, `. peer.conf`), `cron2conf.sh`. Ryzyko resztkowe: `die`
  w podpowłoce zagnieżdżonej w podpowłoce zabija główną powłokę, ale pośrednia
  podpowłoka dokańcza swoje linie — ten sam kształt, który `zfs-restore.sh`
  przyjął 2026-08-27. Obowiązki ręczne `zfsbackup-live-pair` i
  `rux-live-chain` z `impact.sh` NIE wykonane w tej dostawie (zmiana nie
  dotyka parowania, ssh ani ZFS; formaty na dysku bez zmian).
- **`--source-profile` nie działał na formie JEDNOKOMENDOWEJ — jedynej, którą
  operator realnie wpisuje (2026-09-03).** Flaga została wpięta w `cmd_add_client`
  i `cmd_local_backup`, gdy powstawała (#288), a trzecie wejście —
  `zfs-backup.sh --source=HOST:DATASET ...`, czyli to, które SKŁADA
  add-client→seed→activate w jedno — nigdy jej nie poznało i odpowiadało
  `rux: unknown option --source-profile=...`.

  **Skutek zmierzony na labie:** żeby wdrożyć relację z asymetryczną retencją,
  trzeba było rozłożyć ją na `deploy.sh --pair` → ręczny przenos wsadu →
  `--join` → `--commit-scope` → `add-client` → `seed` → `activate`, na dwóch
  hostach — dokładnie tę sekwencję, którą komenda jednoliniowa istnieje po to,
  żeby zdjąć z operatora. Właściciel wskazał to wprost: *"dlaczego nie dało się
  stworzyć relacji podając i source i target w jednej komendzie"*.

  **Naprawa:** czysty passthrough, tego samego kształtu co `--profile` obok —
  deklaracja zmiennej, gałąź w parserze, jedna linia do `add_args`. Walidacja,
  strażnik rodziny i zapis rekordu należą do `cmd_add_client` i nie są tu
  powtarzane. `test/rux` 43 -> 45: przypadek dyskryminujący (pada na starym
  kodzie, przechodzi po poprawce, sprawdzone `git stash`) plus kontrola
  negatywna — pominięcie flagi nie przekazuje PUSTEGO `--source-profile=`.

- **`add-client` wstrzykiwał wymyślony `--mode=backup` do parowania z peerem,
  który już był dataset-driven, trwale zatruwając jego manifest (2026-09-03).**
  Znalezione na żywo w LABIE `--source-profile` (pve9<->pve10, na polecenie
  właściciela: "przetestuj na lab, zrób wdrożenie z niesymetryczną retencją").

  **Przebieg.** `deploy.sh --pair --peer-datasets=hdd/labdata` sparował czysto,
  scope skomitowany. Kolejny `add-client lab10 --source-profile=lab-lean` (bez
  powtórzenia `--peer-datasets`) odświeżył parowanie i wysłał wsad, który
  `--join` na pve10 słusznie odrzucił: *"peer.conf carries both PEER_CONF_MODE
  and PEER_CONF_DATASETS"*.

  **Przyczyna, ustalona `bash -x`.** `cmd_add_client` ma wygodny domyślny wybór
  -- gdy nie dostanie ani `--mode`, ani `--datasets`, sam dopowiada
  `mode=backup`, słuszny dla NOWEGO peera. Zastosowany bezwarunkowo, poleciał
  też dla JUŻ sparowanego, dataset-driven peera -- `do_pair`'s własna logika
  dziedziczenia (`pair_mode_after_inheritance`) nie ma jak odróżnić "operator
  napisał --mode=backup" od "add-client to sobie dopowiedział", więc zbudowała
  wsad niosący OBA pola: dataset lista odziedziczona poprawnie z manifestu,
  i tryb wymyślony przez to wywołanie. Manifest na dysku
  (`peers/<peer>.conf`) został przy tym trwale zatruty --
  `PEER_SAVED_MODE=backup` zapisane tam, gdzie wcześniej było puste, więc
  KAŻDE kolejne parowanie tego peera odziedziczałoby ten sam konflikt.

  **Naprawa.** Domyślne `mode=backup` w `cmd_add_client` jest teraz warunkowe:
  stosowane tylko gdy peer NIE jest jeszcze sparowany (sprawdzone przez
  `peer_manifest_path`/`peer_label`, tym samym idiomem co bramka rerun tuż
  obok). Dla istniejącego peera, gdy operator nie poda ani `--mode`, ani
  `--datasets`, obie zmienne zostają puste -- `deploy.sh --pair` odziedziczy
  wtedy dokładnie to, co manifest już niesie, zamiast dostać zmyślony rozkaz.
  `test/rerun` +6 przypadków, dyskryminujących na starym kodzie (jeden case
  `FAIL MODE=backup DATASETS=` na main, `PASS` po poprawce -- potwierdzone
  `git stash`).

  **Stan po znalezisku:** manifest `peers/192.168.28.97.conf` na pve9 (lab)
  zostaje zatruty aż do wdrożenia tej poprawki i ręcznego re-parowania -- lab
  `--source-profile` NIE jest jeszcze zaliczony, do powtórzenia po deploy.

- **Self-update na koncie bez `rpool` kończył się FATAL na Fazie 8g, cicho, od
  ~5 tygodni (2026-09-03).** Znalezione przy wdrożeniu #291: `deploy.sh
  --self-update` na pve9/pve9b/pve10 (pula `hdd`, nie `rpool`) kończyło się
  `rc=1` na „ZFS delegation" — `apply_repo_to_host` woła `deploy.sh` bez
  żadnych flag, więc zawsze spadało na sztywny domyślny
  `BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"` (Proxmox). Ten default
  istnieje od 2026-07-25; konto delegowane migrowało 2026-08-01 — czyli
  ~840 cogodzinnych przebiegów na hosta kończonych FATAL, nigdy niezauważonych
  (trafiało tylko do `last-apply.log`, nie do maila). Niegroźne praktycznie —
  „skip" nie cofa istniejących uprawnień, wcześniejsze fazy (digest, crontab)
  kończyły się poprawnie — ale exit code był fałszywie czerwony co godzinę.

  **Naprawa, ten sam kształt co `SOURCE_PROFILE`:** zapisz wybór raz, przy
  udanym użyciu, nie zgaduj przy każdym powtórzeniu. `deploy.sh` Fazy 8g, po
  udanym grancie (`GRANTED_COUNT > 0`), zapisuje użytą listę datasetów do
  `$UPDATE_STATE_DIR/grant-datasets` (`write_state_file`, ten sam prymityw co
  `previous-revision`). `apply_repo_to_host` — w obu miejscach, gdzie ta
  funkcja żyje (`update-control.sh` i jej bootstrapowy bliźniak wewnątrz
  `deploy.sh`, oznaczone „kept in sync") — odczytuje ten plik i przekazuje
  `--grant-datasets=<zapisana lista>` do `deploy.sh`; brak pliku = stare
  zachowanie, bez zmian. `test/selfupdate` 25 -> 27, oba nowe przypadki
  dyskryminujące (26 pada na starym kodzie, przechodzi na nowym; 27 to
  kontrola negatywna — bez pliku żadna flaga nie jest wymyślana).

  **Trzy hosty wymagały jednorazowego ręcznego zasiania** (`deploy.sh
  --grant-datasets=hdd`) — wcześniejszy realny grant istniał tylko w `zfs
  allow`, nigdy w nowym pliku stanu.

- **`--unpair` zostawiał ALIASOWY przypięty klucz hosta; digest miał legendę
  sprzed zmiany kolumn (2026-09-03).** Znalezione przy wdrożeniu na flotę:
  `clean-relationships.sh` zgłosił sieroty na pve2 (`pve9`) i pve0
  (`ruxproofB`), oba posprzątane (`--purge`).

  **Przyczyna sierot na pve0.** Cztery pliki klucza na peer, nie trzy:
  keypara, `.pub`, przypięty klucz hosta i jego kopia ALIASOWA (pod
  `HostKeyAlias=zfs-client-<nazwa>`) — **ta, którą wygenerowane linie crona
  faktycznie podają do `-k`**. `do_unpair` kasował tylko trzy; audyt to
  dokumentował komentarzem jako stan trwały zamiast defekt. Poprawione po obu
  stronach (root i konto delegowane), komentarz w audycie skorygowany.
  `test/zfsbackup` 397 -> 399, asercja na treści `do_unpair`, dyskryminująca
  main (2 wzmianki `alias_known_hosts` po poprawce, 0 przed).

  **Przyczyna sieroty na pve2** — sam `.scope.request` z relacji `pve2↔pve9`
  — jest już zamknięta poprzednią zmianą (`--leave` bierze trójkę plików,
  audyt widzi osierocone `.scope*`).

  **Legenda digestu.** Kolumna „czas łączny" zniknęła 2026-09-02 na rzecz
  ostatni/śr./max, ale zdanie *„Transfer = przyrost podzielony przez ŁĄCZNY
  czas przebiegów"* zostało — właściciel zgłosił mail z pve9 jako *„w
  nieaktualnym formacie"*. Sprawdzalność na wierszu odzyskana inaczej: `czas
  śr. × przebiegów` = ten łączny czas, oba czynniki są w tabeli. Marker
  `alert-digest.sh` v35 -> v36. `test/alertmail` asercja treści zaktualizowana
  (pinowała starą legendę, sama by jej zmiany nie złapała).

  **Duchy w digeście — zbadane, ZAMKNIĘTE bez zmiany kodu (2026-09-03).**
  Digest z pve9 wymieniał zadania relacji rozebranych jako „(już nie w
  cronie)" — `replica copy (usbrep1/2/3/weekly)`, `daily snapshot
  (local-labdata)`, kilka labowych. Sprawdzone na żywo na pve9: ostatni wpis
  `local-labdata` w `cron.log` to 2026-09-01 — to ślad tegotygodniowych labów
  z tej sesji, nie coś sprzed miesięcy. Digest ma już własne okno wygaszania,
  `DIGEST_DAYS=7` (2026-09-02) — te wiersze wypadną z tabeli same, najpóźniej
  2026-09-08. Rozwiązanie, o które proszono („własne okno wygaszania"), już
  istniało; robiło dokładnie to, o co proszono. Nie trzeba obcinać `cron.log`
  ani dokładać drugiego mechanizmu.


- **Profil „prunowy" jako właściwy kształt dla retencji źródła (2026-09-03).**
  Właściciel, po przejrzeniu `--source-profile`: *„profil niesie w sobie dużo
  więcej parametrów... takie użycie wydaje mi się karkołomne i nie eleganckie"*.
  Zmierzone: flaga importowała **sześć** rzeczy, gdy chodziło o jedną —
  `retain` (zamierzone), `pattern` (przypięte przez strażnika),
  `prune_schedule`, `notify_word`, `quiesce` (**martwe** — `delsnaps` nie ma
  takiej flagi) i `gfs` (**zmieniające znaczenie cięcia**).

  Rozwiązaniem okazał się pomysł właściciela, nie zmiana w filtrze: **profil,
  który niczego nie tworzy** — bez `[dataset]`, z samym `[prune]`. Waliduje się
  dziś, bez linii kodu, i renderuje po stronie źródła cztery pola:
  `prune_schedule`, `pattern`, `retain`, `notify_word`. Nie ma połowy
  tworzącej, więc nie ma czym przeciec — niezależnie od tego, co akurat jest na
  liście pól usuwanych. To nie nowy mechanizm: `default.conf` już rozdziela
  `[template:standard_hourly]` (tworzy) od `[template:keep_*]` (tylko tnie).
  Opisane w `profiles/README.md` jako **sposób**; przypięte testem, bo obietnica
  w dokumentacji bez testu jest tylko obietnicą.

  Zaniechane świadomie: planowane zawężenie filtru w kodzie. Kształt pliku robi
  to samo lepiej — zakazem z konstrukcji zamiast zakazem w czytniku — i ubywa
  kodu zamiast przybywać.

  **Domknięta przy okazji jedna cicha dziura.** Strażnik rodziny porównywał sam
  `pattern`, więc **drabina GFS w źródle pod płaskim celem przechodziła**:
  `d30h24` i `d30h24-gfs` różnią się jedną linią, obie strony trzymają „30", a
  co innego przez to rozumieją i co innego przeżywa. Rodzina to teraz wzorzec
  **i sposób liczenia**, kluczowany po rodzinie (nie dwa niezależne zbiory, bo
  tiery zamienione miejscami dałyby te same zbiory). `gfs` czytane z obu miejsc,
  w których wolno je zadeklarować: z fragmentu `[prune]` i z tiera. Odmowa
  nazywa kształt: `automated_daily(flat)` vs `automated_daily(ladder)`.
  Kontrola dodatnia: dwie drabiny o różnych liczbach dalej się parują.

  **Nazewnictwo świadomie nietknięte.** Trzy osie z README (cyfry = retencja,
  wielkość liter = kształt, przyrostek = mechanizm liczenia) opisują to, co
  profil TRZYMA. „Nie tworzy" to czwarta oś; nie wymyślam dla niej przyrostka i
  nie wysyłam profilu prunowego w pakiecie — to decyzja właściciela.


- **Retencja asymetryczna: `--source-profile=NAZWA` (2026-09-03).** Źródło z
  ciasnym dyskiem pod kolektorem, który ma miejsca pod dostatkiem, może teraz
  trzymać krótszą drabinę niż cel. Podział źródło/cel **istniał już
  strukturalnie** — `emit_source_prune_fragment` przemianowuje `keep_daily` na
  `src_keep_daily`, REV-20260811-106 odmawia sięgania po autorytet szablonów
  celu, a REV-20260811-107 celowo zachowuje ręcznie edytowaną retencję źródła
  przez reaktywację. Nie dało się tego tylko **powiedzieć przy tworzeniu**,
  więc trzeba było wiedzieć o `src_` i edytować config ręcznie.

  **Pominięcie flagi znaczy dokładnie to, co dziś** — `--profile` na obie
  strony. Warunek właściciela i jedyny bezpieczny odczyt: sięgnięcie po profil
  `default` w źródle po cichu zmieniłoby retencję każdej istniejącej relacji.

  Ścieżka zdalna: `add-client` **zapisuje** `SOURCE_PROFILE=` w rekordzie
  klienta, `activate-client` czyta go przy PIERWSZYM renderze sekcji — ta sama
  granica create-time co `--profile` (REV-088/089). Reaktywacja go nie
  odczytuje ponownie, bo inaczej rendrowałaby po tym, co chroni REV-107.

  **Strażnik rodziny.** Oba profile mogą różnić się tym, ILE trzymają, nigdy
  tym, CO: prune wycelowany w rodzinę, której relacja nie tworzy, nie trafia w
  nic — a `delsnaps` bez trafienia kończy **zerem**. Źródło trzymałoby więc
  wszystko, a raport co noc pokazywał czyste zadanie. Odmowa jest twarda.

  **Dwie wady złapane przez własne testy, obie fail-open:**

  1. strażnik czytał dla celu wprost `PROFILE_PRUNE_FILE`, choć retencja
     profilu bywa w `PROFILE_DS_FILE` (tiery prunujące się same). Cel
     rozwiązywał się do ZERA wzorców, więc funkcja **odmawiała 100% swoich
     poprawnych zastosowań**, z przypadkiem właściciela (`d7h24` pod `d30h24`)
     włącznie — a odmowa czytała się jak rozważny werdykt bezpieczeństwa.
     Teraz obie strony idą przez `profile_retention_fragment`, resolver
     istniejący dokładnie po to, że fragment bywa w jednym albo w drugim pliku;
  2. `SRC_PROFILE_NAME` to zmienna globalna, nigdy nie zerowana na wejściu do
     polecenia: **drugie `add-client` w tym samym procesie dziedziczyło
     `--source-profile` pierwszego**. Pierwsza wersja testu wołała każde w
     osobnej podpowłoce i przechodziła przy żywej wadzie — podpowłoka na
     wywołanie testuje powłokę, nie kod. Teraz oba wołania dzielą proces.

  `test/zfsbackup` 378 -> 388 asercji, w tym kontrola ujemna do każdego
  twierdzenia. Profile w testach to **pliki wysyłkowe**, nie atrapy: `d7h24` i
  `d30h24` niosą te same rodziny na różną długość (asymetria dozwolona),
  `d30` niesie samo `automated_daily` (asymetria odmawiana).

  Literówka i niezgodna rodzina padają w `add-client`, **przed parowaniem i
  wymianą kluczy** — ta sama granica co `--profile`, i odmowa nazywa flagę.
  Bez tego operator, który pomylił jedną z dwóch nazw profili w jednej linii,
  dowiadywałby się o tym przy pierwszym `activate-client` na żywym hoście.

  **DOWIEDZIONE NA ŻYWO 2026-09-03, pve9 (192.168.28.99) -> pve10
  (192.168.28.97).** Oba hosty na gałęzi `7ba4699`, self-update wstrzymany
  mechanizmem samego pakietu (`update-hold`), predykcje spisane PRZED biegiem.
  Profile: cel `d30h24`, źródło `d7h24` — różnią się jedną linią (`keep`), i
  **żaden nie ma bloku `[prune]`**, więc retencja idzie ścieżką
  `PROFILE_DS_FILE`: dokładnie tą, na której strażnik się wykładał.

  | co | wynik |
  |---|---|
  | rekord klienta | `SOURCE_PROFILE=d7h24` obok `PROFILE=d30h24` |
  | render | cel `-D30`, źródło `-D7`, godzinowe `-H24` po obu stronach |
  | zainstalowany crontab | te same liczby, w linii prune każdej ze stron |
  | **prune naprawdę tnie inaczej** | z 39 snapshotów: źródło **7**, cel **30** |
  | literówka | odmowa w `add-client`, nazywa flagę, brak rekordu |
  | niezgodna rodzina | odmowa; `target patterns` **niepuste** |
  | kontrola ujemna: bez flagi | `-D30` po OBU stronach |

  Wiersz `target patterns: [automated_daily automated_hourly]` jest osobnym
  dowodem poprawki: przed nią ta lista była pusta i odmowa trafiała każdego.

  Punkt czwarty — reaktywacja nie nadpisuje ręcznej edycji (REV-107) — wyszedł
  przez odmowę, która sama jest dowodem: po ręcznej zmianie źródłowego `-D7` na
  `-D3` nowo wyrenderowany blok niósł `-D3`, a instalacja stanęła dlatego, że
  zainstalowany crontab wciąż miał `-D7`. Gdyby reaktywacja przeładowała
  zapisany preset, render dałby `-D7` i odmowy by nie było.

  Lab rozebrany do zera: `remove-client` + `--leave`, datasety skasowane,
  crontaby wrócone do stanu sprzed labu, oba klony z powrotem na `main`
  @ `2eb209a`, aktualizacje wznowione, `clean-relationships.sh` czysty na obu.

  Obowiązek `zfsbackup-live-pair` jest tym pokryty **poza `setup-server`** —
  oba hosty były już postawione, więc ten krok nie był wykonywany.
  `rux-live-chain` (topologia łańcuchowa RUX) **zostaje otwarty**.
- **Dwie wady znalezione przez lab `--source-profile`, obie niezwiązane z tą
  funkcją (2026-09-03).** Wyszły przy rozbiórce labu pve9 -> pve10, każda z
  kontrolą, która oddziela je od zmienianego kodu.

  **1. Ręczna edycja retencji blokowała instalację.** Operator zmienia `retain`
  w zainstalowanym configu i reaktywuje; `assert_target_block_not_clobbered`
  odmawia, radząc *„move the other workload out of this account first"* — a
  jedyne zadanie, które wymienia, to właśnie to edytowane. Kontrola: edycja
  retencji **celu** `-D30`→`-D25` daje identyczną odmowę, więc to nie ma nic
  wspólnego z `--source-profile`.

  To blokowało przepływ, który **REV-20260811-107 ZATWIERDZIŁ** tymi słowami:
  *„Administrator edits only remote SOURCE retention... because the production
  source is space-constrained"*, a potem zwykła reaktywacja. REV-107 sprawił,
  że **kompozycja** zachowuje tę edycję — i zachowuje, dowiedzione na żywo —
  ale jego dowodem była suita jednostkowa, więc strażnik instalacji nigdy nie
  stanął na tej ścieżce. Polityka zachowana i odrzucona przy drzwiach.

  Strażnik miał już trzy zwolnienia („to samo zadanie, zmienione w jednym
  wymiarze": endpoint, wchłonięte pokrycie, minuta). Doszło czwarte, na
  retencję, i **jako jedyne mówi na głos** — nazywa starą i nową wartość,
  bo retencja to ilość historii. Dopasowanie jest wąskie: flaga musi być całym
  argumentem poprzedzonym białym znakiem, więc dataset o nazwie
  `tank/rack-D7` zostaje nietknięty. Kontrola ujemna: zadanie na **innym**
  datasecie dalej jest kasowaniem i dalej jest odmawiane.

  **2. `--leave` zostawiał trzeci plik scope, a audyt nie mógł go zobaczyć.**
  Draft scope to trio: `.scope`, `.scope.sha256` i `.scope.request`.
  `deploy.sh` sam zna tę parę w ścieżce odmowy (*„rm $sfile $sfile.request"*),
  a sprzątanie kasowało dwa z trzech. Zmierzone na pve9: po pełnym `--leave`
  został `pve10.scope.request`, wskazujący skasowany dataset dla nieistniejącej
  relacji.

  Druga połowa jest gorsza: `clean-relationships.sh` odkrywa identyfikatory z
  `peers/*.conf`, `rel/*/` i kont delegowanych. Ślad, który nie ma żadnego z
  tych trzech, był **nieodkrywalny**, nie tylko niewypisany — audyt odpowiadał
  „nothing orphaned", czyli jedyną odpowiedź, którą ma obowiązek mieć dobrze.
  Osierocone `.scope*` zasiewa teraz własny identyfikator. Dyskryminator:
  kod sprzed poprawki 0 wzmianek, po poprawce 3.


- **Silniki: pre-pass długich opcji miał DRUGĄ kopię option-stringa i kopie się
  rozjechały (2026-08-31, zmiana w plikach ZAMROŻONYCH za zgodą właściciela).**
  `OPTSTRING` — z którego pre-pass czyta, które litery biorą argument — był
  utrzymywany ręcznie, tuż pod komentarzem mówiącym wprost, że ręcznie
  utrzymywana lista dryfuje i że dryf będzie cichy. Lista, którą naprawdę
  parsuje `getopts`, była osobnym literałem sto linii niżej; gdy dopisano tam
  `-E`, tutaj nie. Pre-pass uznawał więc `-E` za boolean, brał NAZWĘ rodziny za
  pierwszy argument pozycyjny i — regułą samego getopts — **kończył na niej
  przetwarzanie opcji**:

  ```
  $ snapsend.sh -E foo --recursive=flat tank/a tank/b
  snapsend.sh: illegal option -- -
  $ snapsend.sh -X foo --recursive=flat tank/a tank/b     # kontrola: przechodzi
  ```

  Ten sam kształt, odwrotna odpowiedź, a jedyna różnica to litery, które druga
  kopia akurat niosła. `-t` zdryfowało tak samo i było nieszkodliwe tylko
  dlatego, że jest booleanem. Poprawka to **skasowanie kopii**: `getopts`
  konsumuje teraz `$OPTSTRING`, więc rozbieżność przestała być wyrażalna;
  wartość stringa jest ta sama, którą getopts już parsował.

  Nic z tego, co generuje pakiet, nie było dotknięte — `gen-cron.sh` emituje
  wyłącznie krótkie opcje, więc żadna linia crona na estacie nie może nieść
  łamiącego kształtu. Łamie się operatorowi piszącemu oba zapisy razem i
  wszystkiemu spoza pakietu, co woła silniki. `test/recursion` **70/0**, trzy
  nowe przypadki na silnik; kontrola negatywna wobec poprzednich silników:
  66 przechodzi, padają dokładnie cztery asercje dyskryminujące.
  `./test/impact.sh --refreeze` wykonany, wpis w `ENGINE-FREEZE.md`.

  **Suity wymagające roota/ZFS/drugiego hosta przeszły na pve9 (2026-09-01),
  przeciwko `3eefe61`, z jednorazowego klonu — trzy produkcyjne klony pve9
  nietknięte na `main`:** `test/snapsend` **202/0** (własna pula na pliku
  rzadkim), `test/scenarios` **36/0** (`--parent hdd`), `test/remote`
  **145/0** (pve9 → pve2 po ssh; pve1 nie wpuszcza roota z pve9).
  **`nonroot-account` spełniony** tego samego dnia: ta sama kampania jako
  konto delegowane, `zfsbackup@pve9 → zfsbackup-pve9@pve2`, **145/0**.
  Wymagała jednorazowego, wąskiego nadania na pve2 (`zfs allow` na jednym
  datasecie scratch) — nadanie cofnięte i dataset skasowany po biegu,
  listy datasetów obu hostów zdiffowane przed/po: identyczne.

- **ETAP PROFILI, krok 1: worek `flags` rozbity do końca (2026-08-31).**
  `flags` w sekcji `[dataset:]` niósł trzy różne własności naraz. Oś **łącza**
  (`bandwidth`, `compression`, `cipher`) wyszła 2026-08-24 w `6d71a3b`; teraz
  wyszła oś **zakresu** — `passive` (`-e`), `exclude_family` (`-E`, lista po
  przecinku) i `exclude_child_<n>` (`-X`, numerowane, bo wartość to REGEX i może
  zawierać każdy separator, który wybrałaby lista). W `flags` zostaje sama
  **tożsamość**: `-K -k -O -p` — i to jest odtąd powód, dla którego pole jest
  profile-forbidden.

  Każde pole renderuje ten sam token i w tej samej kolejności co zapis ręczny —
  asercja przez wyrenderowanie obu i porównanie wywołania silnika. Kolejność jest
  częścią kontraktu, bo przestawiony `flags` to szum w każdym `crontab diff`.
  Ta sama opcja z `flags` i z pola jest odmawiana, nie scalana; `passive = no`
  obok ręcznego `-e` też, i to jest ostrzejszy przypadek — `no` nie renderuje
  nic, więc nie ma duplikatu, jest tylko config czytający odwrotnie, niż działa.
  Nowa suita `test/scopefields` 35/0 z wbudowaną kontrolą negatywną.

  Przy okazji dwa defekty, oba zmierzone z kontrolą:
  `gen-cron.sh` nie wiedział, że `-E` bierze argument, więc zbundlowane
  `-Erepl_` (legalne dla obu silników) czytał jako pięć opcji i wymyślał literę
  `r` — config wykluczający rodzinę na `r` był odrzucany za „deklarowanie
  rekursji"; `-Ebulk_` wymyślało `-b` i kolidowało z polem `bandwidth`.
  Drugi: profil mógł wpisać do bloku `[dataset]`/`[prune]` pole, które relacja
  i tak pisze do tej samej sekcji (`recursive`, `send_schedule`) — duplikat pola
  to twarda odmowa `gen-cron`, więc taki profil unieruchamiał każdą relację
  z niego zbudowaną, a błąd nazywał duplikat, nigdy profil. Odmawiane teraz przy
  walidacji profilu. Do bloku `[dataset]` zostają `use_template` i `media`.

  **Nazwy ujednolicone 2026-09-01** (polecenie właściciela: „pilnujemy
  spójności pakietu na każdym etapie, to ma wejść pod GUI"): `exclude_family`
  (lista po przecinku, rodziny snapshotów) i `exclude_child_<n>` (numerowane,
  regexy dzieci), a w CLI `--exclude-family` / `--exclude-child`, w rekordzie
  `EXCLUDE_FAMILY_n` / `EXCLUDE_CHILD_n`. Nazwa niesie teraz **rodzaj listy**,
  której dotyczy — reguła spisana w `docs/project/FOUNDATIONS.md`. Stare
  pisownie **usunięte, nie aliasowane**; kosztowało jeden commit, bo pola miały
  jeden dzień i nie było ich w żadnym configu na estacie (sprawdzone na
  **pięciu** hostach — pve9, metropolis pve1/pve2, pve0, 11.11: zero rekordów
  `EXCLUDE_*`, zero pól w configach).

  Zgodność wstecz: **pominięcie pola = dzisiejsze zachowanie, co do bajta** —
  z 26 istniejących golden fixture'ów nie zmienił się ani jeden. Stare
  pisownie w CLI i w configu kończą się **głośnym** błędem. Trzecia,
  **rekord klienta**, zawiodłaby po cichu (czytelniki szukają nowych nazw, więc
  stary rekord wróciłby jako „brak wykluczeń", a reaktywacja zgubiłaby każde
  `-X` i `-E` bez słowa) — dlatego `load_client_and_connection` **odmawia**
  na `EXCLUDE_SNAP_n` / `EXCLUDE_n`, nazywając zamiennik. Ta odmowa nie
  powinna nigdy wystrzelić i właśnie dlatego istnieje: „nigdy" jest tu
  twierdzeniem o pomiarze, nie o kodzie.

  **Domknięte 2026-09-01:** `passive` i `exclude_family` dostały warstwę
  `[template:]`, więc profil wreszcie MOŻE o nich mówić — a sekcja relacji
  nadal wygrywa, bo `resolve_field` czyta ją pierwszą. Żadnego silnika
  precedencji, użyta warstwa, która już była. `exclude_child_<n>` zostaje
  sekcyjne i zakazane w profilu z tego samego powodu co `recursive`: które
  DZIECI tego źródła zostawić to zdanie o kształcie jednego drzewa, którego
  profil użyty do dziesięciu źródeł nie zna.

  Zweryfikowane **na labie**, nie w atrapie: relacja `tltest` na pve9 z
  profilem deklarującym te pola, prawdziwy rekord, prawdziwy `emit_client_
  sections`, prawdziwy `gen-cron`. Wyemitowana sekcja `[dataset:]` nie niesie
  ANI JEDNEGO pola zakresu, a linia crona wychodzi jako
  `snapget.sh -m "automated_hourly_" -K … -e -E __replicate_ -E vzdump -A -L
  tltest …` — czyli `-e` i obie rodziny przyszły z profilu. Relacja usunięta,
  rekordy i crontab konta zdiffowane przed/po: identyczne.

  **`ssh_flags` też zakazane w profilu (2026-09-01).** Znalezione przy
  wypisywaniu właścicielowi, co profil MOŻE nieść, zanim zacznie pisać profile
  fabryczne: `ssh_flags` to tożsamość połączenia dla zdalnego prune
  (`-p/-k/-c/-K/-O`, ten sam zestaw co `flags`), a `append_source_prune_create`
  sam wpisuje to pole do sekcji — więc profil z `ssh_flags` powodował, że
  sekcja niosła je dwa razy i `gen-cron` odrzucał cały config. Ta sama rodzina
  co `recursive` i `send_schedule`; wymknęło się regule „ma warstwę
  `[template:]`, więc jest polityką", bo **nie ma żadnej warstwy template**.
  Zmierzone: przed poprawką profil przechodził walidację.

  **Katalog domknięty na trzech mechanizmach (2026-09-01).** `d30h24` i `d7h24`
  dostały warianty `-gfs` i `-age`, wyprowadzone z wysyłanych profili ze zmianą
  **wyłącznie** sposobu liczenia retencji. Gołe nazwy zostają płaskim
  licznikiem, więc każda retencja jest nazywalna we wszystkich trzech trybach i
  żaden nie jest domyślany po cichu.

  **Złapane renderowaniem, nie walidacją.** Pierwsza wersja tej derywacji nie
  zmieniła **niczego**: drzewo robocze jest CRLF, moje wzorce kończyły się na
  `
`, więc każde podstawienie po cichu nie trafiło — a cztery pliki, będąc
  dokładnymi kopiami profili, które i tak się walidują, przeszły
  `profile_validate_file` i przeszłyby suitę katalogu. Pokazało to dopiero
  wyrenderowanie sześciu obok siebie i zobaczenie **identycznych** linii
  `delsnaps`. Profil, który się waliduje, to nie profil, który mówi to, co
  napisałeś.

  **Katalog: cztery profile czterorodzinne (2026-09-01).** Do długiej formy
  `y5m12d31h24-{gfs,age}` doszła chuda: **`m12w4d7h24-{gfs,age}`** — 12
  miesięcznych, 4 tygodniowe, 7 dobowych, 24 godzinowe, czyli miesiąc pokrycia
  zamiast pięciu lat, z tierem tygodniowym w miejsce rocznego. Reszta reguł bez
  zmian: cztery przedrostki (żeby grube tiery dało się quiesce'ować bez
  zamrażania każdego gościa 24× na dobę), godzinowy nigdy nie quiesce'owany,
  `,degrade`, trzy rodziny proxmoksowe ogrodzone, brak `dst`.

  Zweryfikowane na labie prawdziwą ścieżką `--target=''`; nowy tier tygodniowy
  uruchomiony dosłownie: `exit=8` i `automated_weekly_crash_...`. Oba mechanizmy
  na tej samej rodzinie podają **różne powody**, nie tylko różne flagi —
  `(newer than threshold)` kontra `(GFS W#1)`.

  **Ryzyko resztkowe nazwane i ZAAKCEPTOWANE, nie zamknięte (decyzja
  właściciela 2026-09-01).** Profil bez własnego `[prune]`, którego tiery też
  nie mają `prune_schedule`, wyrenderuje snapshoty bez retencji. Bramki na to
  **nie budujemy**: retencję może prowadzić coś spoza pakietu (`pvesr` robi
  dokładnie to na własnych rodzinach), więc bramka odmawiałaby poprawnych
  wdrożeń. To narzędzie administratora — odmowy zostają tam, gdzie chronią
  cudze dane, nie tam, gdzie zgadują intencję. Zapis w `OWNER-DECISIONS.md`;
  zapowiedź tej zmiany w „Remaining risk" odpowiedzi na REV-132 jest tym samym
  nieaktualna.

  **12 z 14 profili nie dawało się wdrożyć Z CELEM — naprawione, PR #256
  (2026-09-01).** Kampania labowa właściciela (trzy kształty wdrożenia × cały
  katalog) trafiła w twardą odmowę: sekcja `[prune:<cel>]` wklejała fragment
  `[prune]`, którego profil tnący się z tierów po prostu nie ma, więc powstawała
  sekcja bez `use_template`, a `gen-cron` odrzucał kandydata
  (`error: [prune:hdd/labtarget] has no use_template`). **`prod` i `d30` padały
  też, więc dziura jest starsza niż profile z tego dnia** — to ta sama klasa,
  dla której powstał `profile_declares_ladder` po incydencie z `prod`: zamknięta
  na ścieżce zdalnej i nigdy niezadana na lokalnej.

  Za odmową siedziała druga wada, którą odmowa **zasłaniała**: z celem blok
  retencji źródła leciał dla każdego profilu, więc profil bez fragmentu tnie
  źródło dwa razy — raz drabiną z tierów, raz płasko z rodziny źródłowej, i
  płaskie cofa drabinę. To ta sama duplikacja, którą REV-132 zmierzył w trybie
  bez kopii; warunek napisano jako „bez kopii LUB własny fragment", gdy jedyne
  pytanie brzmi „czy tiery już tną źródło". Po poprawce 14/14, a `default` i
  `passive` renderują się bit w bit tak samo, bo rozwiązują się do tego samego
  pliku.

  Lekcja tej rundy jest ta sama co przy CRLF dzień wcześniej, tylko z drugiej
  strony: **odmowa na ścieżce potrafi ukryć wadę za sobą.** Duplikacja retencji
  była tam przez cały czas i żaden test jej nie widział, bo konfiguracja nie
  dochodziła do renderu.

  **Kształt dwuhostowy: dwa znaleziska, NAPRAWIONE — i okazały się jedną
  wadą złożoną z dwóch (decyzja właściciela „bierz wady", 2026-09-01).**

  Pierwsze: przy peerze z zapamiętanym trybem generator wypuszczał pakiet,
  który jego własny `--join` odrzuca — `peer.conf carries both PEER_CONF_MODE
  and PEER_CONF_DATASETS`. Gałąź re-parowania dziedziczyła `PEER_SAVED_MODE`
  bezwarunkowo, choć gałąź świeżego parowania obok wymusza „albo tryb, albo
  lista". Wywołujący był poprawny przez cały czas: `zfs-backup.sh` podaje
  `--mode` ALBO `--peer-datasets`. Decyzję wydzielono do
  `pair_mode_after_inheritance` — nazwanie datasetów W TYM wywołaniu jest
  wyborem formy datasetowej, a dziedziczenie zostaje dla przypadku, dla
  którego powstało: re-parowania, które nie nazywa niczego.

  Drugie: **przerwany create nadpisywał manifest peera** (`PEER_SAVED_DATASETS`),
  choć rekord relacji się nie ruszał — a `client_section_plan` renderuje
  z manifestu, więc kolejny `migrate-profile` po cichu przecelowywał żywą
  relację na dataset, którego nigdy nie backupowała. Naprawione tym samym
  wzorcem, który cel relacji miał już wcześniej: rekord bije manifest per-host
  (`REQUESTED_DATASETS` → `PEER_SAVED_DATASETS`, pod strażnikiem `-n`, bo tryb
  sync i stare rekordy żadnej prośby nie niosą).

  **Wiązanie, które widać dopiero razem.** `resolve_mode_datasets` — normalnie
  rozwiązujący listę z podpisanego zakresu źródła — na manifeście niosącym
  ORAZ tryb, ORAZ listę robi `return 0` od razu. Czyli pierwsza wada wyłącza
  resolver, a dopiero to pozwala drugiej ugryźć: bez trybu w manifeście lista
  zostałaby przeliczona z zakresu i rozjazd by się nie utrwalił. Zmierzone na
  pve9, nie wywnioskowane — i to jest powód, dla którego regresja B ustawia
  w manifeście testowym oba pola naraz.

  **DIGEST PRZEBUDOWANY: NAJPIERW STAN, POTEM HISTORIA (`alert-digest.sh` v9->v11,
  2026-09-02).** Zgloszenie wlasciciela: rano przyszedl mail
  `pve1.kancelaria.net -- 2 alert / 1 warn` z pula DEGRADED, choc dysk wymieniono
  dzien wczesniej. **Pula byla zdrowa** — `zpool replace` 2026-09-01 17:45:12,
  scrub bez bledow, mirror pelny, oba ESP zarejestrowane w `proxmox-boot-tool`
  (czyli system startuje z kazdego dysku; `zpool replace` sam tego nie robi).

  **v10 — etykieta.** Digest chodzi o 07:00 nad kolejka zapelniona poprzedniego
  dnia, a naglowek bral date WYSYLKI (`TODAY`). Powstawalo `Doba: 2026-09-02` nad
  `(07:01 - 16:01)` — zdarzeniami sprzed poltorej godziny przed naprawa. Teraz
  naglowek nazywa okres wyliczony ZE ZDARZEN, a wiersz spoza dnia wysylki niesie
  date; dzisiejszy zostaje zwiezly, bo data w kazdym wierszu to szum.

  **v11 — struktura, na polecenie wlasciciela ("to jest nieczytelne i mylace dla
  admina").** Sama uczciwa etykieta nie wystarczyla: czytelnik nadal wnioskowal
  terazniejszosc z listy zdarzen przeszlych. Mail ma teraz trzy bloki w tej
  kolejnosci:

  1. **STAN BIEZACY, mierzony w chwili wysylki** — zdrowie i zapelnienie pul oraz
     ostatni przebieg kazdego zadania. Werdykt (`STAN: OK` / `UWAGA`) idzie takze
     w temacie. To jest wlasciwa naprawa: **fakt naprawiony nie ma jak udawac
     biezacego, bo ten blok jest SONDA, nie odtworzeniem**.
  2. **ZDARZENIA Z OKRESU** — jak dotad, wyraznie jako historia.
  3. **PRZEBIEGI ZADAN** — per zadanie: liczba, bledy, czas sredni i najdluzszy.

  Zasada jednego maila dziennie bez zmian: bloki jada tylko wtedy, gdy mail i tak
  wychodzi. Cichy host dalej milczy.

  **Wada mojego wlasnego projektu, zlapana dopiero uruchomieniem na pve9.**
  Pierwsza wersja pokazala `STAN: UWAGA` przez zadanie, ktore padlo dzien
  wczesniej i **zostalo usuniete z crona** po kampanii labowej. Jego ostatni
  przebieg zostaje w logu na zawsze, wiec werdykt zawiesilby sie bezterminowo bez
  niczego do naprawienia. Stan sadzi teraz tylko zadania nadal obecne w crontabie;
  usuniete sa oznaczone i zostaja w tabeli przebiegow, gdzie sa faktem
  historycznym. Regresja pilnuje OBU stron.

  **Wolumen swiadomie pominiety (decyzja wlasciciela: "na razie same przebiegi").**
  `announce_transfer_size()` istnieje, a mbuffer liczy bajty od zawsze — ale oba
  sa zagluszone, gdy stderr nie jest terminalem, zeby cron nie zamienil
  `cron.log` w miernik predkosci. Odsloniecie tego to zmiana sciezki danych w
  ZAMROZONYCH silnikach; tanszy wariant to przekierowanie podsumowania mbuffera
  do pliku stanu, drozszy to `zfs send -nP` z dodatkowa runda SSH na przebieg.

  Czasy liczone z SEKUND DOBY, nie `mktime` — cala estata ma **mawk** (zmierzone
  na pve1.kancelaria, pve9 i pve2), a `mktime` to rozszerzenie gawk; gawkizm
  padlby po cichu wszedzie. Dowiedzione na WYGENEROWANYM skrypcie i na prawdziwym
  `cron.log` pve9. `test/alertmail` 41/0.


  **v12 (2026-09-02, tego samego dnia co v11): DWA FORMATY CRONA i pelny dataset
  w tabeli.** Wlasciciel przeczytal prawdziwy mail z pve0 i zglosil dwie rzeczy.

  **Wada, ktora wypuscilem w v11.** Na pve0 KAZDE zadanie bylo opisane jako
  „juz nie w cronie", co jest po prostu nieprawda. v11 szukalo etykiety jako
  `zfs-job.sh "<label>"` -- tak wyglada crontab wygenerowany przez biezacy main.
  Hosty produkcyjne nosza starszy format WBUDOWANY, gdzie etykieta siedzi
  wewnatrz wlasnego `echo` zadania:

      1 * * * * echo "$(date -Is) ZFS-JOB BEGIN pve0 hourly backup (...)" >>...

  Na takim hoscie nie pasowalo nic. **Format odczytany z JEDNEGO hosta nie jest
  formatem estaty** -- wzorzec wyprowadzilem z pve9, ktory chodzi na swiezym
  main. Dopasowywane sa teraz oba zapisy; oba daja "<host> <etykieta>", z ktorej
  pierwsze slowo odpada, zeby zgadzalo sie z logiem. Zmierzone na prawdziwym
  crontabie pve0: 19 zadan, wszystkie `ostatni OK`.

  **Pelny dataset pod wierszem tabeli.** Etykieta niesie tylko slowo z `notify`
  -- `daily backup (BIM server)` nazywa maszyne, nie zbior danych -- wiec sam
  wiersz nie odpowiada na pytanie „ktory dataset". Linia crona odpowiada, wiec
  datasety sa z niej wyciagane i wypisywane pod wierszem.

  Filtr datasetow: token w cudzyslowie, ktory zawiera ukosnik, NIE zaczyna sie
  od ukosnika i NIE MA SPACJI. Bez ostatniego warunku wciagalo tekst z `echo`,
  bo na pve0 etykieta brzmi doslownie `hdd/lxc` i sama zawiera ukosnik.

  `test/alertmail` 44/0, dziesiec przypadkow digestu -- w tym crontab w starym
  formacie, ktory jest ta regresja, ktora by mnie uratowala.


  **v13 (2026-09-02): przecinki zamiast plusow, dataset przy KAZDYM zadaniu,
  mail krotszy o jedna trzecia.** Wlasciciel przeczytal maila z v12 i wskazal
  dwie rzeczy: `daily backup (vm-101)` nie mowi, ze chodzi o
  `hdd/data/vm-101-disk-0`, a `vm-103-disk-0+vm-104-disk-1+...` powinno miec
  przecinki.

  **Dataset w bloku STANU, nie tylko w tabeli.** Nawias w etykiecie to slowo z
  `notify`, wiec czasem jest lista datasetow, a czasem nazwa ludzka („BIM
  server"). Blok stanu wypisuje teraz pod kazdym zadaniem to, czego faktycznie
  dotyczy -- wyciagniete z linii crona.

  **`+` naprawione w WYSWIETLANIU, nie w generatorze, i to jest wybor.** Znak
  powstaje w `gen-cron.sh:3263` (`IFS=+`) przy scalaniu kilku datasetow w jedna
  linie crona. Zmiana u zrodla przepisalaby etykiete w KAZDEJ wygenerowanej linii
  crona, wiec crontab kazdego hosta roznilby sie przy najblizszej regeneracji, a
  straznik anty-kasujacy zobaczylby stare linie jako usuniete. To ten sam koszt,
  ktory wlasciciel odrzucil przy `-X/-e/-E`. Digest zamienia `+` na `,` przy
  wypisywaniu; jesli maja byc przecinki u zrodla, to osobna zmiana z regeneracja
  crontabow na estacie.

  **Datasety wypisywane RAZ.** Pierwsza wersja pokazywala je w obu blokach --
  zmierzone na pve0: 149 linii, z czego okolo 50 to duplikat. Zostaja w bloku
  stanu (ten odpowiada na „co to za host i co obejmuje"); tabela przebiegow
  odpowiada na „jak chodzilo" i nazwa zadania wystarczy, zeby je zlaczyc.
  Po zmianie 104 linie.

  `test/alertmail` 46/0, dwanascie przypadkow digestu.


  **KATALOG: `Y5M12D31H24` — pierwszy profil WIELKOLITEROWY (2026-09-01).**
  Pięć lat pokrycia, JEDNA rodzina, drabina `-G -H24 -D31 -M12 -Y5`, i nic
  nigdy nie zamrażane.

  Luka była węższa, niż brzmiała na początku: `default` **już** nie zamraża
  niczego, więc administrator bez agentów nie stał z pustymi rękami. Brakowało
  DŁUGIEJ retencji bez zamrażania — `default` kończy się na miesiącu, a `m12`
  i `y5` istniały wyłącznie w profilach małoliterowych, które mrożą każdy tier
  powyżej godzinowego. „Pięć lat, i niczego nie mogę zamrozić" (goście bez
  agenta, czyste systemy plików, przyszła adaptacja LVM/ext4) nie miało
  odpowiedzi i oznaczało ręczną edycję profilu.

  **Żadnego nowego przyrostka nie wymyślono.** Konwencja już istniała: reguła
  właściciela z 2026-08-27 mówi, że mała litera to jedna rodzina na tier, a
  WIELKA to jedna rodzina pod kilkoma licznikami — czyli dokładnie ten kształt.
  Reguła nie miała dotąd żadnego mieszkańca (`default` jest tym kształtem, ale
  pod nazwą-stałą), więc to jej pierwszy.

  Niezamrażany **z konstrukcji, nie z wyboru**: na jednej rodzinie snapshot
  dobowy JEST jednym z dwudziestu czterech godzinowych, które drabina zachowała,
  więc quiesce nie może być per tier — to dwadzieścia cztery zamrożenia dziennie
  albo żadne. Dlatego plik nie ustawia `quiesce` wcale, zamiast ustawiać go na
  wyłączony.

  **Suita pominęłaby ten plik W MILCZENIU.** Filtr nazw w `test/profiles` brzmiał
  `^([dhwmDHWM][0-9]+)+$` — bez kadencji rocznej — więc `Y5M12D31H24` nie
  pasował do niczego i kontrola nazw/kształtu nigdy go nie widziała: przechodziła,
  nie sprawdzając go w ogóle. Klasa rozszerzona o `yY` w trzech miejscach, które
  ją zapisują. Dowiedzione kontrolą pozytywną — po podmianie `keep` rocznego na 9
  suita zgłasza `Y5M12D31H24(missing -Y5); Y5M12D31H24(unpromised-Y9)`, a przed
  poprawką filtra milczała.

  Profil daje też wielkoliterowej gałęzi `shape_verdict` pierwszy prawdziwy
  przedmiot z katalogu. Mógł powstać, bo **nie ma małoliterowego bliźniaka**: na
  systemie plików nierozróżniającym wielkości `D30H24.conf` i `d30h24.conf` to
  jeden plik i zapis jednego KASUJE drugi (zmierzone 2026-08-27). To drugi powód,
  żeby gołe `y5m12d31h24` zostało zarezerwowane i niewysyłane.

  **LAB SYNC/PASSIVE ZAMKNIĘTY — ostatnia luka kampanii (2026-09-01).** Nie dało
  się go zrobić na pve9: `src8`/`src9` zajmują całą przestrzeń
  `hdd/backups/<host>`, więc strażnik pokrycia odmawiał drugiej relacji.
  Postawiony **pve10** (VM 111 na pve2, `192.168.28.97`) — kolektor bez żadnej
  relacji. Relacja `lab1`: pve10 ← pve1 `hdd/labsrc`, tryb sync, profil
  `passive`.

  Kontrakt pasywny dowiedziony **kontrolą rozróżniającą**, nie samym „źródło bez
  zmian" (to by znaczyło tylko tyle, że zadanie było bezczynne): źródło 78 → cudza
  ręka tworzy snapshot → 81 → po biegu zadania **nadal 81**, a kolektor 3 → 6.
  Zadanie przeniosło dane i mimo to nie stworzyło na źródle niczego. Linie
  uruchamiane dosłownie z zainstalowanego crontaba, jako konto delegowane.

  **ZNALEZISKO I JEGO NAPRAWA — ostrzeżenie, nie strażnik.** Drabina zostawia
  najnowszy snapshot w kubełku, a baza replikacji jest zwykłym snapshotem —
  więc JEDEN snapshot zrobiony ręcznie na landingu może być nowszy, wygrać
  kubełek i **wypchnąć bazę**. Zmierzone: 7 → 3, dataset nadrzędny zachował
  wyłącznie snapshot ręczny, następne pobranie odmówiło (`shares no common
  snapshot (by GUID)`, `rc=1`, alert) i relacja stanęła do decyzji człowieka.

  Naprawy przez zakaz **nie ma i nie będzie** — kierunek właściciela z
  2026-08-09 (`PREFIXLESS-PASSIVE-GFS`) mówi wprost, że szerokie czyszczenie
  bezprefiksowe jest destrukcyjne z projektu, ale nie jest nieprawidłowe, a
  narzędzie „nie ma wymyślać zakazu tylko dlatego, że coś jest szerokie".
  Ten sam zapis pozwala jednak **stwierdzić fakt w podglądzie** — i tego
  brakowało. Plan relacji mówi teraz, że drabina obejmuje każdy snapshot na
  landingu wraz z bazą, w idiomie, który ten plik już miał: `(to fakt, nie
  zakaz)`. Pojawia się wyłącznie dla profilu bezprefiksowego; `default`, `prod`
  i `d7h24-gfs` milczą, bo ostrzeżenie drukowane wszędzie to szum, a przez szum
  przeoczy się to jedno, które miało znaczenie.

  Uboczna obserwacja, odnotowana i nieścigana: `check-snap-age` przy wzorcu bez
  dopasowania porównuje wiek ZAKRESU, więc świeży landing wygląda zdrowo do
  progu ostrzegawczego, a potem alarmuje. Profilu `passive` to nie dotyczy —
  jego `pattern = -` dociera do monitora jako wartownik `(any)` i dopasowuje.

  **DWA P1 OD RECENZENTA, oba moje, oba naprawione (REV-131, REV-132).**
  W wyjątku dla `gfs` dopasowałem pole **przed** sprawdzeniem rodzaju sekcji,
  więc objął też blok `[dataset]` — a `resolve_field` czyta sekcję przed
  szablonem, czyli jedno `gfs = yes` po cichu przestawiało **wszystkie** tiery
  z licznika na kubełki czasowe. Nic nie padało; profil małymi literami po
  prostu zaczynał renderować drabiny. Wyjątek zawężony do `[prune]`.

  Groźniejszy drugi: wyłączyłem blok retencji źródłowej przy `--target=''`, bo
  przy `y5m12d31h24-gfs` **dublował** cięcie (osiem linii zamiast czterech,
  płaska znosiła drabinę). Uogólniłem z jednego profilu. Dla `default` tiery nie
  mają `prune_schedule` — retencja siedzi wyłącznie w bloku `[prune]` — więc
  wychodziła **jedna linia tworząca snapshoty i zero tnących**: poprawny config,
  chodzące zadania, pula rosnąca bez końca. Rozstrzygnięte pytaniem, które
  narzędzie już zadaje (`schedule_tier_exprs`): profil z własnym fragmentem
  `[prune]` dostaje sekcję źródłową, profil bez niego tnie tierami. Zmierzone na
  labie dla trzech profili: `default` 0 → 1 ograniczona drabina, pozostałe bez
  zmian po cztery.

  Katalog dostał **sufiks mechanizmu**, bo nazwa mówiła liczby i kształt rodzin,
  ale nie sposób liczenia: `-gfs` (kubełki), `-age` (wiek), goła nazwa
  zarezerwowana dla domyślnego licznika.

  **WDROŻENIE JEDNOSERWEROWE BEZ KOPIOWANIA (2026-09-01).** Forma
  bezczasownikowa — `zfs-backup.sh --source=... --target='' --profile=...
  --install` — instaluje zadania, które robią snapshoty i **nic nie wysyłają**.
  Pusty `--target=''` jest intencją; **pominięty** nadal proponuje cel, więc
  żadna dzisiejsza komenda nie zmienia znaczenia. Zapis lustruje CONFIG v4,
  który to narzędzie generuje: `dst =` puste to jedyne pole, gdzie pustka
  znaczy „brak celu", a nie błąd. Pusty cel **nie instaluje się pod `--yes`** —
  bo to samo daje niezdefiniowana zmienna powłoki.

  Bieg na labie odsłonił trzy rzeczy, których czytaniem kodu nie znalazłem:
  retencja źródłowa dublowała cięcie (dwie linie na tę samą rodzinę w tej samej
  minucie, jedna z drabiną, druga płaska — płaska zniweczyłaby drabinę);
  delegacja próbowała **utworzyć** cel (`zfs create -p -- ''`); seed wysyłał
  pusty drugi argument zamiast wołać silnik w tym samym kształcie, co
  instalowane zadanie. Wszystkie trzy zamknięte.

  **Dowód end-to-end na koncie delegowanym** (pve9, konto `zfsbackup`):
  zainstalowane i odczytane zwrotnie, crontab konta urósł z 16 linii do 28 i
  **żadna ze starych nie zniknęła**; linia dobowa uruchomiona jako konto dała
  `ZFS-JOB END rc=8` oraz wpis `ALERT` w kolejce powiadomień, ze snapshotem
  `automated_daily_crash_...`. Degradacja quiesce jest więc zgłaszana, a nie
  księgowana jako czysty przebieg — `zfs-job.sh` z założenia zawsze kończy się
  zerem i kieruje niezerowy wynik silnika do skryptu powiadomień. Po teście
  crontab i config konta przywrócone i zdiffowane — identyczne; testowy wpis
  usunięty z kolejki alertów, żeby nie poszedł w digeście.

  **DRABINA NA TIERZE (2026-09-01, polecenie właściciela „to jest
  konieczne").** `gfs = yes` można teraz postawić na tierze `[dataset:]`/
  `[template:]`, przez co linia prune TEGO tieru niesie `-G`: rodzina jest
  cięta **kubełkami czasu**, nie płaskim licznikiem. Wcześniej niewyrażalne —
  `gfs` żył tylko w `[prune:]`, a jego projekt to JEDNA linia `-G` nad JEDNĄ
  rodziną; cztery drabiny na jednym datasecie wymagałyby czterech sekcji
  `[prune:<ścieżka>]`, a nagłówek jest kluczem (zmierzone: `duplicate
  section`).

  Różnica nie jest kosmetyczna, zmierzona na pve9 na trzech snapshotach
  w jednej godzinie (tak wygląda nadrabianie po przerwie): płaskie `-H2`
  zostawiło dwa najnowsze — dwie sekundy historii — a `-G -H2` jeden na
  kubełek godzinowy. **`gfs` wszedł do klucza scalania** linii prune: tier
  z drabiną nie skleja się z płaskim, bo linia niesie `-G` albo nie, dla
  każdego datasetu, który wymienia.

  Nowy profil **`y5m12d31h24-gfs`** (5 rocznych, 12 miesięcznych, 31 dobowych,
  24 godzinowe; cztery przedrostki, cztery jednoszczeblowe drabiny; wszystko
  poza godzinowym `quiesce = auto,degrade`; nic nigdzie nie kopiowane).
  Zweryfikowany na labie liniami crona uruchomionymi DOSŁOWNIE: hourly exit 0,
  daily **exit 8** ze snapshotem `automated_daily_crash_...`, a prune godzinowy
  zostawił jeden snapshot z trzech i **nie tknął rodziny dobowej**.

  **CZĘŚĆ WSADOWA ZAMKNIĘTA — decyzja właściciela 2026-09-01.** Emisja
  `-X/-e/-E` zostaje w `flags`: funkcjonalnie nie dawała nic (oba zapisy
  renderują tę samą linię silnika), a kosztowałaby różnicę w crontabie na
  całej estacie przy najbliższej reaktywacji każdej relacji. Wartość nazwanych
  pól leży w tym, że mówi o nich warstwa wyższa, i to działa już teraz.
  Pełny zapis w `docs/project/OWNER-DECISIONS.md`. Etap profili nie ma
  dalszych kroków; kolejny etap jest po stronie GUI.

  **Czego ten etap świadomie NIE robi:** pola zakresu są profile-forbidden (węziej, niż
  chce `PROFILE-VARIABLE-INVENTORY.md` §5) — brakuje warstwy `[template:]` i CLI
  odróżniającego „nie" od „nic nie powiedziano"; `zfs-backup.sh` **nadal pakuje**
  `-X`/`-e`/`-E` do `flags`, bo przełączenie go przepisuje sekcje całej estaty
  przy reaktywacji i to jest osobna decyzja właściciela.

  Do rozstrzygnięcia przez recenzenta: zdanie „recursion remains profile-owned"
  z REV-20260808-076 powstało, gdy nie było rekursji na poziomie relacji; dziś
  jest, więc implementacja poszła za kodem.

- **Monit potwierdzenia był nieodpowiadalny ze strumienia — `ssh` zjadało stdin (2026-08-23).**
  `ssh` bez `-n` czyta swoje wejście do końca i przekazuje je zdalnej komendzie. Żadne
  wywołanie w `zfs-backup.sh` tego nie chce, ale **każde połykało** to, co niósł stdin
  operatora. `seed` i `activate` rozwijają zakres peera przez `ssh` **przed** zapytaniem
  o potwierdzenie, więc obie komendy odmawiały „not confirmed" niezależnie od tego, co im
  podano. Na terminalu działa (stdin to tty), więc wada nie pokazywała się w ręcznych
  testach — tylko w automatyzacji i transkryptach. Zmierzone na pve9:
  `printf 'ZOSTALO' | { ssh root@peer true; read -r x; ... }` → `[PUSTO]`.
  `-n` na wszystkich dziesięciu wywołaniach; żadne z nich niczego do `ssh` nie podaje,
  a przyszłe, które będzie musiało, ma `-n` zdjąć świadomie i to uzasadnić.
  Test behawioralny z kontrolą: przed poprawką `[PUSTO]`, po `[ODPOWIEDZ]`, plus kontrola
  kompletności, żeby nowe wywołanie bez `-n` nie wśliznęło się później.
  Ta kontrola od razu się przydała: złapała, że mój własny komentarz rozpadł się na dwie
  linie i druga **nie była komentarzem**, tylko żywym kodem w środku pliku. `bash -n`
  tego nie widziało, bo cudzysłowy domykały się dalej.
  **Sama poprawka `zfs-backup.sh` była jednak niewystarczająca, wbrew temu, co tu wcześniej
  napisałem.** Sprawdzone na żywo: `activate` dalej odmawiał, bo catch-up po drodze woła
  **silnik**, a `snapget.sh` też zjadał stdin. Zmierzone wprost — `printf | snapget.sh -n …;
  read` → `[PUSTO]`. Domknięte zmianą w zamrożonych silnikach za zgodą właściciela:
  `-n` na **38** wywołaniach czytających w `snapget.sh`, `snapsend.sh`, `delsnaps.sh`
  i `lib-zfs-snap.sh`. **Cztery zostały nietknięte celowo** — niosą ładunek na stdin
  (potok `zfs send | ssh … zfs recv` ×2, próba przepustowości, skrypt quiesce przez
  `bash -s`) i `-n` zerwałoby tam transfer. Wpis w rejestrze zamrożenia wymienia je z nazwy.
- **`activate --host=` nie działał po zainstalowaniu crona — przy ŻADNEJ zmianie
  endpointu (2026-08-23).** Nie „przy zmianie portu" — przy każdej. Pierwsze przełączenie
  w życiu relacji przechodziło wyłącznie dlatego, że nie było jeszcze bloku crona do
  porównania; każde następne strażnik odrzucał, biorąc **własne** zadania relacji za obcy
  workload, który zaraz zniknie. Kontrola izolująca: `--host=<ten sam>` → `EXIT=0`,
  `--host=<inny host:port>` → `EXIT=1` i „2 job line(s) would be DELETED", a obie
  wymienione linie należały do tej właśnie relacji.
  Wyjątek dla przełączenia endpointu **istniał** (REV-042/043) i był **martwy**: napisano
  go pod kształt `-A "acct@host:path"`, którego `gen-cron.sh` już nie emituje — `-A` to dziś
  flaga autotune, a endpoint jest argumentem pozycyjnym. Zmierzone na linii wziętej
  dosłownie z żywego crontaba: stary wzorzec **nie podmieniał niczego**. Do tego port żyje
  w osobnej fladze `-p` i nigdy nie podróżował z hostem, a linia zdalnego prune
  (`delsnaps.sh`) niesie endpoint pozycyjnie — mimo że komentarz przy wywołaniu twierdzi,
  że linie `delsnaps.sh` „nie mają połączenia zdalnego do przełączenia".
  Normalizowane są teraz wszystkie trzy pisownie, i **tylko** one: konto, dataset źródłowy,
  docelowy, harmonogram, retencja i `HostKeyAlias` nadal porównywane co do znaku, więc
  zadanie, które naprawdę znika, nadal jest zgłaszane (kontrole fail-closed z REV-043
  przechodzą bez zmian).
  Dołożona kontrola, której brakowało: test sprawdza, że wyjątek **żyje** — że normalizator
  faktycznie przepisuje linię w emitowanym kształcie. Kolejny dryf kształtu zrobi się
  czerwony zamiast cichy. To trzeci raz tego dnia, gdy zielony test był przypięty do
  kształtu, którego produkt już nie ma.
  **Pierwsza poprawka nadal nie wystarczyła — i wpadła w tę samą pułapkę.** Zamieniała
  `-p 2222` na `-p <PORT>`, co zrównuje strony tylko wtedy, gdy **obie** niosą flagę.
  Tymczasem `gen-cron.sh` przy porcie 22 **nie emituje `-p` w ogóle**, więc powrót na
  endpoint LAN porównywał linię z `-p <PORT>` z linią bez niczego i strażnik dalej odmawiał.
  Fikstura testu miała `-p 22` po obu stronach — kształt, którego narzędzie nigdy nie
  produkuje. Port jest teraz **usuwany**, nie podmieniany, a test renderuje **obie** strony
  prawdziwym `gen-cron.sh` z dwóch configów różniących się wyłącznie endpointem i
  **asercjonuje samą przesłankę** (że wersja portu 22 nie ma `-p`). Człowiek zniknął z pętli.
- **Dwie wady cyklu życia, które ujawniła dopiero druga próba czterech komend (2026-08-23).**
  Obie znalezione na żywo (pve9 → pve2), obie blokowały samą próbę, żadnej nie dało się
  zobaczyć czytaniem kodu.
  **Nazwy nie dało się użyć ponownie.** `remove-client` celowo **zostawia** rekord relacji
  i dopisuje `STATE=removed` — to jej własna historia. `add-client` odrzucał jednak każdy
  istniejący plik, niezależnie od stanu. Po całkowicie czystej rozbiórce (blok crona,
  sekcje configu, klucze, konto na peerze, zero `zfs allow` — wszystko sprawdzone) kolejny
  krok tego samego cyklu odmawiał i kazał uruchomić `remove-client`, czyli komendę, która
  właśnie przebiegła i nic by nie zmieniła. Dwie połowy cyklu, każda spójna wewnętrznie,
  wzajemnie sprzeczne. Nagrobek jest teraz **archiwizowany** poza przestrzeń `*.conf`,
  którą skanują wszystkie pętle, a nazwa wraca do użytku; rekord w każdym innym stanie
  nadal odmawia i odmowa **nazywa ten stan**.
  **Każdy endpoint na porcie innym niż 22 nie przechodził weryfikacji klucza hosta.**
  Przy `HostKeyAlias` OpenSSH szuka klucza pod **samym aliasem** — nie dokleja portu, jak
  robi to dla prawdziwej nazwy hosta. `ensure_alias_known_hosts` zapisywał `[alias]:port`,
  więc klucz leżał pod nazwą, o którą ssh nigdy nie pyta. Port 22 działał i tylko dlatego
  wada przetrwała — nic w estacie nie używało innego portu aż do przełączenia endpointu.
  Awaria jest myląca: klucz **jest** w pliku, a `ssh -v` mówi to wprost
  (`hostkeys_find_by_key_cb: found matching key`, zaraz potem `Host key verification failed`)
  — bo to szukanie po KLUCZU ze skanu `UpdateHostKeys`, gdy szukanie po NAZWIE już chybiło.
  Zmierzone: klucz przypięty był co do bajtu równy prawdziwemu kluczowi pve2, a ten sam
  wpis bez portu przepuścił identyczne połączenie. Przypinany jest teraz sam alias — i to
  jest też znaczeniowo poprawne: zmiana portu nie zmienia tego, kim jest peer.
  Testy pytają **własny matcher OpenSSH** (`ssh-keygen -F`), a nie grepują nawiasu.
- **ETAP: PASYWNOSC DEKLARATYWNA (2026-08-23, po LAB-E).** Pasywnosc jest DECYZJA
  operatora zapisana przy utworzeniu (`--passive`, takze w rux), nigdy zgadywanka z nazw:
  seed adoptuje najnowszy istniejacy snapshot (goly -e, zadnej sondy automated_), silniki
  dostaly -E PREFIX (wykluczone rodziny nie moga byc baza; najnowszy niewykluczony wygrywa
  - dowiedzione para dyskryminujaca na zywo), monitor ma jawny tryb dowolny (wzorzec '-')
  z wykluczeniami -x, wbudowany profil `passive` (szablony bezprefiksowe, drabinka GFS bez
  gfs_pattern), relacja pasywna NIE dostaje prune zrodla (rodzina nalezy do obcego
  systemu). Do tego z mapy audytu: rehearsal bez fallbacku automated_ dla sekcji z -e;
  nagrobki STATE=removed niewidzialne dla rux (dwuznacznosc i kontrola istnienia);
  PLAN=base=null juz NIE potwierdza incremental-only; add-client --local-user prowizjonuje
  swieze konto kolektora (repo, notify-skrypty, grupa zfsalert, run) - trzy odmowy
  aktywacji z LAB-E znikaja u zrodla; --exclude-family=CSV plynie w flags (-E), do
  monitora (monitor_exclude -> -x) i jest czescia klucza grupowania monitorow (dwa
  monitory rozniace sie slepymi polami nie moga dzielic linii). Wiek monitora w minutach
  ponizej 2h. Kampania zamykajaca etap: na zywo po CI.
  Korekta z CI: prowizja konta jest BEST-EFFORT, nie twardym useradd - egzekutorem
  pozostaje straznik uruchamialnosci przy aktywacji, ktory nazywa brakujacy kawalek;
  wolajacy bez roota pomija z logiem zamiast umierac (kazdy test --local-user na
  prawdziwym cmd_add_client padal na useradd w kontekscie CI).
- **KAMPANIA LAB-E: pasywnosc wobec CUDZYCH snapshotow (2026-08-23, wieczorem).** Plan
  wlasciciela: caly ruch -e takze w trybie backup; cudze rodziny (cudzy_/smiec_/bez
  prefiksu) generowane cronem co 5 min na zrodle; dwa cykle (root+join reczny+atomowy -r;
  bckp+join automatyczny --grant-remotely+plaski -R z wykluczonym dzieckiem); monitory maja
  ignorowac starzejace sie cudze SPOZA wozonej rodziny.
  **Dowiedzione na zywo:** silnik juz umie model wlasciciela (-e bez maski = najnowszy,
  jakkolwiek sie nazywa - zmierzone); pelna pasywnosc w obu cyklach (md5 listy snapshotow
  zrodla identyczne przed/po, wielokrotnie); wykluczenie dziecka pod kontem delegowanym;
  --grant-remotely z audytem; monitor: zielony na swiezych cudzych -> WARN 13 min ->
  CRITICAL 21 min po zgaszeniu generatora, z nazwa datasetu.
  **Dziewiec znalezisk** (pelna lista w zapisie kampanii): seed stempluje mimo cudzej
  rodziny (x2); pasywnosc niewyrazalna przy enrolacji; monitor odmawia bezprefiksowosci;
  -r atomowy wiezie bagaz innych rodzin (semantyka ZFS -R), plaski nie; pasywnosc
  per-dataset przy prefiksowanym szablonie niewyrazalna (wlasny szablon dziala); rux liczy
  nagrobki STATE=removed (rodzina #124); **regresja -n z #127 zabila --grant-remotely**
  (stanza przez wrapper -> pusty plik zakresu; strazi gramatyki utrzymal fail-closed;
  naprawione wariantem stdin-carrier z dyskryminatorem); rux --local-user nie prowizjonuje
  konta kolektora (repo, notify-skrypty, grupa) a wykluczone dziecko dostaje
  PLAN=base=null i liczy sie do 'incremental-only confirmed'; wiek monitora drukowany w
  pelnych godzinach ukrywa minuty przy progach minutowych.
  **AUDYT ZAKLADNIKOW automated_:** silniki, gen-cron, restore, cron2conf, lib-* - CZYSTE
  (wzorce z configu/argumentow). Zakladnicy WYLACZNIE w zfs-backup.sh, 6 miejsc, wspolny
  korzen: sonda rodziny (pfx domyslnie automated_) + seed z zaszytym -m automated_daily_.
  Z audytu wynika tez przewidywanie dla testu aktywnego z innym prefiksem: profil
  prefix=serwis_ rozdwoi rodzine na starcie, bo seed stempluje automated_daily_ na sztywno.
  **Wniosek architektoniczny:** sync nigdy nie byl pasywny OGOLNIE - byl pasywny
  LANCUCHOWO: jego sonda widzi tylko automated_*, a poligon (lancuch naszych instancji)
  spelnial to zalozenie z definicji. Etap 'pasywnosc deklaratywna' ma kompletna mape:
  flaga relacji zamiast sondy; sonda zostaje tylko jako straznik lancucha w sync.
- **PELNA SEKWENCJA WDROZENIOWA na koncowym main dnia - czysty przelot, ktory wisial od LAB6
  (2026-08-23, main@91d9734, pve9<->pve2).** Jeden cykl zycia od zera przez WSZYSTKIE
  dzisiejsze poprawki naraz, kazda w swoim naturalnym miejscu toru, zadna nie dowodzona
  osobno na boku:
  K1 add-client: nazwa po rozbiorce uzyta ponownie, nagrobek zarchiwizowany (#124).
  K2 join: `t` odrzucone (monit powtorzony), liczba przyjeta, 22->4 datasety, produkcja
  zero grantow (#117). K3 seed po LAN BEZ --yes, odpowiedz ze strumienia (#127/#128);
  podglad z INNEJ sesji w trakcie: `running 42% 256 KiB/s` obok `verified` (warstwa
  danych); GUID zgodny po obu stronach. K4 activate przez tunel 10.99.0.2:22 ze strumienia,
  cron przepisany na endpoint tunelowy (#125/#126). K5 linia crona DOSLOWNIE: rc=0,
  +50 KiB licznikiem wg0, cztery rekordy `verified` - nie `ok` (#121/#134). K6 status:
  teraz/ostatni wynik/nastepny krok (#130-B). K7 restore: plan relacji bez flag (#133),
  trzy odmowy R-025 na zywo, safe restore z GUID-em ZWERYFIKOWANYM do hdd/restore,
  produkcja nietknieta. K8 check v4: zdrowy host MILCZY (kolejka 2->2) - kontrola
  negatywna #131 na zywo. K9 clean rerun: crontab i CONFIG IDENTYCZNE co do md5, 4->4
  linie, seed odmawia stanem, activate no-op. K10 rozbiorka: zero grantow, konto
  usuniete, nazwa uzyta TRZECI raz.
  Jedna nieczystosc, nazwana: w K3 podglad w locie pochodzil z rownoleglego dlawionego
  transferu obok seeda (wyscig o zamek) - wlasciwosci pokazane, ale stan koncowy
  dowodzi seed + GUID, nie tamten przebieg.
- **Restore dostal publiczne drzwi: adresy relacyjne z odmowa zamiast zgadywania (2026-08-23).**
  Gramatyka wlasciciela z 2026-08-13 (`restore pve2`, `restore pve2:rpool/data`, sciezka
  zarzadzanej kopii) miala od poczatku jedna zasade rozbrajajaca dwuznacznosc: **nazwa,
  ktora sie nie rozwiazuje, to blad - nigdy zgadywanie**. Zadnego fallbacku do hostname,
  DNS ani sondy ssh, bo koszt zgadniecia to destrukcyjne odtworzenie wycelowane w zla
  maszyne. Trzy ostrza R-025 wprost w resolverze: `user@host:dataset` odrzucane (transport
  nie nalezy do powierzchni publicznej); gole slowo NIGDY nie staje sie hostname; obca
  sciezka NIGDY nie jest adoptowana jako kopia. Kazda odmowa nazywa powod i bezpieczny
  nastepny krok (`restore --plan`).
  Adres pozycyjny wpiety w parser: z `--snapshot` wymaga dokladnie JEDNEGO datasetu -
  odtworzenie calej relacji do jednej nazwy snapshotu ozywiloby falszywa idee, ze rowne
  nazwy to jedno zdarzenie atomowe (zmierzone na pve2, ze nie sa). Bez `--snapshot` adres
  przechodzi w plan zawezony do relacji. Druga pozycyjna (cel miedzy hostami) odmawia z
  nazwana sekwencja R-025 - te drzwi wisza po recenzji tych.
  Siedem dyskryminatorow w test/restore, w tym wszystkie trzy odmowy R-025 osobno.
  Zywy dowod po wdrozeniu zlapal ostatnia luke: na prawdziwym hoscie publiczna pisownia
  umierala o brak configu, bo jedyny mechanizm jego odkrycia opieral sie na szczatkowym
  server.conf (zmierzone: nieobecny na kazdym hoscie). Fallback to deterministyczna LOKALNA
  konwencja jobs.<host>.conf, ktora pisze i czyta cala reszta narzedzia - nie zgadywanie w
  sensie R-025; odmowa nadal wymienia, czego sprobowano. Dowod: restore pve2 bez flag na
  pve9 -> plan z /etc/zfs-snapshot-all/jobs.pve9.conf; restore pve7 -> odmowa z nazwa.
  Recenzent znalazl dwuznacznosc, potwierdzona pomiarem: nazwy datasetow ZFS legalnie
  zawieraja ':', a resolver dzielil kazdy token z dwukropkiem jako label:dataset ZANIM
  rozwazyl zarzadzana sciezke - legalna kopia `.../pool/data:archive` byla odrzucana, choc
  siedziala w CONFIG-u. Siedem testow bylo zielonych, bo zaden nie uzywal nazwy z
  dwukropkiem. Regula dalej nie zgaduje: dokladne dopasowanie verbatim wygrywa; gdy OBA
  odczyty pasuja naraz, odmowa nazywa oba. Trzy nowe dyskryminatory w test/restore.
- **Monitor zaczal konsumowac warstwe danych: zdrowie puli i martwe transfery (2026-08-23).**
  Dwie dziury, za ktore estata juz zaplacila: `rpool` na pve1 byl **DEGRADED tygodniami** bez
  jednego alertu (pojemnosc sprawdzana codziennie, zdrowie NIGDZIE - zdegradowana pula
  transferuje normalnie, az padnie drugi dysk); oraz wiszacy transfer, ktorego alert
  zadaniowy strukturalnie nie widzi, bo strzela na niezerowy KOD WYJSCIA, a wiszacy potok
  nigdy nie wychodzi.
  `check-pool-capacity.sh` v4 (ta sama linia crona 08:00, ten sam kanal kolejki, zero nowych
  procesow): kazda pula != ONLINE to znalezisko z doczepionym `zpool status`; rekord
  `running` bez odswiezenia od 30+ min (odswieza co 2 s) to znalezisko wskazujace
  `zfs-backup.sh progress`. Kontrole negatywne przypiete na rowni z pozytywnymi: pula
  ONLINE, zywy transfer i stary ZAKONCZONY rekord milcza - alert strzelajacy tak czy siak
  uczy filtrowania. Testy jada na PRAWDZIWYM wygenerowanym skrypcie (test/alertmail, 27/27).
- **Widac, ile zostalo - w trakcie transferu, nie po (2026-08-23).**
  Do tej pory transfer milczal az do konca. Na seedzie 4 TB to godziny ciszy, a jedyna
  uczciwa odpowiedz na „jak daleko jest” brzmiala „poczekaj”. `mbuffer` pokazuje tempo na
  terminalu, ale tempo **bez sumy** nie powie, ile **zostalo**, i jest niewidoczne z kazdego
  innego okna niz to, ktore uruchomilo przelot.
  Zrodlem liczb jest `zfs send -v -P` - sam ZFS, zero nowych zaleznosci. Zmierzone na
  zfs-2.1.11: naglowek `size<TAB><bajty>` od razu, potem linia na sekunde z suma narastajaca,
  a w kierunku **pull** te same linie wracaja przez stderr ssh nienaruszone. Jeden mechanizm
  dziala wiec w obu silnikach.
  Warstwa zlecajaca ma czasownik `progress`: pokazuje **wszystkie** transfery w locie -
  procent, tempo, pozostaly czas - **z dowolnego terminala**. Zmierzone na zywo:
  `running 3.9 MiB / 8.1 MiB (48.3%) 192.5 KiB/s pozostalo 0h00m22s`, dziesiec sekund
  pozniej `5.9 MiB / 8.1 MiB (73.1%)`.
  **Alert jest chroniony i to byla trudna czesc.** Stderr wysylki to zarazem miejsce, gdzie
  przychodza jej **bledy**, a sciezka alertowania bierze z niego `tail -n 8`. Linie postepu
  zostawione w tym strumieniu zamienilyby powod awarii na licznik bajtow. Dlatego stderr
  trafia do osobnego pliku, czytnik czyta go obok, a linie postepu sa **usuwane** przed
  odtworzeniem pliku na stderr. Zmierzone: zero linii postepu w logu skryptu podczas
  prawdziwego transferu.
  **Nieswiezy rekord mowi, ze jest nieswiezy** - podglad dopisuje „bez aktualizacji od Ns
  - moze nie zyc” zamiast pokazywac zamrozona liczbe jako aktualna. Rekordy zakonczone sa
  sprzatane po tygodniu; rekord `running` **nigdy** - skasowanie go zniszczyloby jedyny slad,
  ze cos padlo.
  **Granica pomiaru, zapisana zamiast ukryta:** `-v` liczy bajty **wepchniete do potoku**,
  nie dostarczone. Przy kompresji i buforze mbuffera roznica to glebokosc bufora - na 4 TB
  nieistotna, na malym zbiorze „100%” pojawi sie chwile przed koncem odbioru. Liczenie po
  stronie odbiorczej kosztowaloby drugi strumien; nierobione.
  **Etap wprowadzil regresje i zlapala ja dopiero kontrola na zywo, nie CI.**
  `[ $_pg_rc -ne 0 ] && return 1` jako OSTATNIE polecenie galezi zwraca 1, gdy warunek jest
  falszywy - i to staje sie kodem wyjscia funkcji. Kazdy **udany** transfer w kierunku push
  meldowal `Transfer failed`, bez przyczyny, bo zadnej nie bylo. CI dawalo 30/30.
  Znalezione przez puszczenie prawdziwego push na kodzie SPRZED zmiany jako kontroli - tam
  ten sam transfer konczyl sie `All datasets processed successfully`. Gdyby to weszlo na
  `main`, flota zaczelaby alarmowac o backupach, ktore dzialaja: odwrotnosc falszywego
  zdrowia, ale to samo zatrucie alertowania.
  Poprawione w szesciu miejscach obu silnikow i przypiete **ksztaltem, nie pisownia**: zadna
  ksiegowosc postepu nie moze konczyc galezi golym testem.
  **Rekord jest kluczowany TOZSAMOSCIA ZADANIA, nie nazwa datasetu (advisory recenzenta,
  #129).** Pierwsza wersja budowala nazwe pliku, zamieniajac `/` i `@` na `_` - co nie jest
  roznowartosciowe. Potwierdzone pomiarem przed przyjeciem: `pool/a_b@s` i `pool/a/b@s` daly
  ten sam plik, wiec postep jednego zadania po cichu stawal sie postepem drugiego. Dataset
  jest zlym kluczem takze z drugiego powodu: to samo zrodlo moze isc rownoczesnie do dwoch
  roznych celow, a to sa rozne zadania.
  Uzyty zostal **istniejacy** `job_state_key` - hashuje kierunek, IDENTIFIER, zrodlo i cel
  z separatorem NUL, wlasnie po to, by zadna wartosc nie mogla udawac granicy (REV-001 F3).
  Jedna definicja tozsamosci zadania w pliku, nie druga obok. Czytelna nazwa datasetu i celu
  zostaje **w srodku** rekordu, a podglad pokazuje `zrodlo -> cel`.
  **Warstwa danych dla maszyn, nie tylko oczy (kierunek wlasciciela, 2026-08-23).** Sens
  etapu: pakiet ma wiedziec, jak idzie transfer datasetu, jak idzie CALA relacja i jak
  wygladalo to wczesniej - zeby przyszle GUI albo monitor mogly to zbadac bez skrobania
  tekstu. Dlatego: rekord niesie **relacje** (`label` z `-L`), **tryb i baze** wyprowadzone
  z prawdziwej komendy send (`full`/`incremental`/`resume`), **tozsamosc zadania** oraz
  **bajty na laczu** z logu mbuffera (`wire_bytes`; `-1` = niemierzalne, nigdy 0, zeby brak
  pomiaru nie czytal sie jako bezczynne lacze; mierzalne w pull, w push mbuffer biegnie po
  stronie zdalnej). Historia JSONL dostala pole `label` (dokladane - starzy konsumenci
  czytaja dalej). `progress --json` zwraca surowe rekordy per zadanie ORAZ agregat per
  relacja. `status` odpowiada: co biegnie TERAZ, jaki byl OSTATNI wynik, co dalej - i brak
  historii nazywa 'nie wiadomo', nie 'bez awarii'. Zmierzone na zywo: przy kompresji
  done_bytes=0 (send skonczyl przed pierwsza linia postepu - opisana granica), a
  wire_bytes=1441792 mowil prawde o laczu w locie. Dwie miary, obie uczciwe.
  **Trzy wady kontraktu znalezione przez recenzenta, potwierdzone pomiarem i naprawione
  (2026-08-23).** (1) Tozsamosc zadania hashowala SNAPSHOT (ostatni token komendy send),
  wiec jedno skonfigurowane zadanie produkowalo nowy plik na kazdy przebieg, a resume nie
  dzielil tozsamosci z przebiegiem, ktory wznawial - zmierzone: trzy rozne hashe dla
  jednego zadania; siedmiodniowy reaper po cichu maskowal wyciek. Klucz to teraz sam CEL
  (jeden dataset laduje w jednym miejscu; stabilny przy snapshotach i resume), zrodlo i
  snapshot zostaja w rekordzie jako dane. (2) Agregat relacji mieszal zakonczone rekordy
  z zywymi: gotowy 100/100 + biezacy 25/100 dawal 200/125 'running' zamiast 100/25 -
  agregat liczy teraz wylacznie state=running, historia zostaje w jobs. (3) Stan 'ok'
  zapisywal sie PRZED weryfikacja GUID (wpis w rejestrze zamrozenia twierdzil odwrotnie -
  to jest korekta tamtej deklaracji): po validate_snapshot rekord awansuje ok->verified
  albo ok->verify_failed, wiec konsument odroznia 'procesy nie padly' od 'dane sa
  dowodnie na celu'. Piec dyskryminatorow w twins (58/58).
- **Zgoda na zakres przy `--join` kosztuje teraz tyle, ile jest warta (2026-08-22).**
  Zmierzone na wymaganym przez #9 torze czterech komend: kolektor podał wyłącznie
  `--target`, więc źródło nie miało czego zawęzić i zaproponowało **cały swój
  majątek** — 22 datasety, w tym wszystkie wolumeny maszyn. Jedno naciśnięcie
  `t` nadało labowemu kolektorowi `snapshot,destroy,send,hold` na produkcyjnych
  dyskach pve2, w tym na `subvol-101-*`, czyli bramie OpenVPN. Cofnięte w ciągu
  minuty, zweryfikowane `zfs allow` (zero wpisów) — ale to nie był błąd
  wykonania, tylko zachowanie produktu na jego własnej normalnej ścieżce.
  **Propozycja nie jest zawężana** i celowo: to jest narzędzie do backupu
  Proxmoksa, wolumeny gościa zwykle SĄ ładunkiem, a heurystyka, która by je
  chowała, myliłaby się częściej niż trafiała. Zmieniona jest cena zgody:
  monit mówi wprost, że kolektor **nie wskazał niczego** i że propozycja to
  cały host; podaje wielkość (ile datasetów, ile wolumenów maszyn, ile bajtów)
  **zanim** zada pytanie; i przyjmuje zgodę tylko przez **wpisanie liczby
  datasetów**, bo odruch jest tu jedyną rzeczą, która naprawdę zawodzi.
  Sama liczba jest jednak warta tyle, ile jej **związanie z grantem**, a pierwsza
  wersja nie wiązała nic. Podgląd i grant liczyły zakres **osobno**: podgląd
  zamieniał nieudany odczyt na mniejszą liczbę (błąd `scope_read` → „0 0 0", root
  bez `zfs list` → pominięty, nieudany `zfs get used` → zero bajtów), po czym
  `do_commit_scope` enumerował pulę **jeszcze raz** i nadawał to, co znalazł.
  Wszystkie trzy pomyłki szły w tę stronę, która sprzedaje zgodę za tanio.
  Teraz jest **jeden** enumerator dla obu, każdy nieudany odczyt to **odmowa**
  zamiast mniejszej liczby, zbiór jest deduplikowany, a zaakceptowana liczba
  **i zbiór** są sprawdzane w `do_commit_scope` **przed pierwszym `zfs allow`**.
  Dowód wykonywalny w `test/joinmanifest/run.sh` (prawdziwy `do_commit_scope`,
  sterowalny `zfs`, każdy przypadek liczy faktyczne wywołania `zfs allow`).
  Kontrola na odrzuconej bazie: dryf inwentarza między pytaniem a grantem kończył
  się `rc=0` i **trzema wykonanymi `zfs allow`** na zbiorze, którego nikt nie
  zaakceptował; po poprawce — odmowa i zero grantów.
- **Tydzień bez zdarzeń też musi się odezwać (2026-08-22).**
  Do tej pory pusta kolejka znaczyła brak maila, więc **cisza nie niosła żadnej
  informacji**. Zmierzone na pve9: jego MTA dostarczał wyłącznie lokalnie, a
  digest nie był w ogóle zaplanowany, więc host nie raportował niczego przez
  **miesiące** — a ze skrzynki właściciela wyglądało to identycznie jak host bez
  zdarzeń. W `/var/mail` na samym hoście leżały trzy prawdziwe wiadomości, w tym
  digest nazywający 2 alerty i 1 ostrzeżenie.
  Od teraz raz w tygodniu, w poniedziałek, host bez zdarzeń mówi o tym wprost.
  Jedna linia, jeden mail na host na tydzień. Nie chodzi o treść — chodzi o to,
  że **od poniedziałku BRAK maila sam jest alarmem**, i to alarmem, który
  właściciel zauważa bez zaglądania gdziekolwiek.
  Bezstanowo z rozmysłem: żadnego pliku „ostatni puls", który mógłby się
  zestarzeć, rozjechać albo wrócić z backupu — **dniem tygodnia JEST harmonogram**.
  Poniedziałek, który ma zdarzenia, wysyła zwykły digest i dowodzi tego samego.
  Dowód na żywo: pusta kolejka w sobotę → zero maili; pusta kolejka w dniu pulsu
  → mail dostarczony na zewnątrz, `250 Ok`.
  Puls **zawodzi zamknięcie**: pierwsza wersja wpychała do `mail` i kończyła
  bezwarunkowym `exit 0`, więc zepsuty MTA raportował „kanał sprawny" mimo że nic
  nie opuściło hosta — dokładnie ta awaria, którą puls ma ujawniać, w przebraniu
  samego pulsu. Teraz o werdykcie decyduje kod wyjścia wysyłki. Zmierzone na pve9:
  `mail` działa → `rc=0`; `mail` zwraca 3 → `rc=1` i na stderr „the alert channel
  on this host is NOT proven". Przypięte behawioralnie w `test/alertmail/run.sh`
  (uruchamia prawdziwy wygenerowany skrypt, nie grepuje źródła).
- **Zakolejkowane zdarzenia odchodzą razem z relacją (2026-08-22).**
  Znalezione na żywo: kolejka alertów pve1 trzymała cztery zdarzenia o relacjach
  zdemontowanych wiele godzin wcześniej, a najbliższy digest o 07:00 wysłałby
  właścicielowi mail o backupach, które już nie istnieją. Ani `remove-client`,
  ani `clean-relationships.sh` nie tykały kolejki, więc **każda rozbiórka
  zostawiała swoje skargi do doręczenia później**, bez kontekstu i bez adresata.
  Tak umiera alerting — ten projekt ma na to rachunek: 384 maile w jedną noc i
  odruch `MAILTO=""` zamiast naprawy.
  Zdarzenia **nie są kasowane**: przy purge przenoszą się do nagrobka relacji,
  czyli do pliku, który i tak istnieje po to, żeby być ostatnią rzeczą nazywającą
  to, co po niej zostało. Historia zostaje tam, gdzie zajrzy pytający, a digest
  raportuje tylko to, co nadal prawdziwe. Dopasowanie po etykiecie, którą monitor
  sam wpisuje w nawiasie, więc nie może się rozjechać z rekordem. Dowód na żywej
  kolejce pve1: 4 wpisy → 1, trzy przeniesione do nagrobka jako `QUEUED_ALERT=`,
  wpis niezwiązany nietknięty.

- **Digest jest zadaniem HOSTA, nie relacji — pve9 przez to milczał (2026-08-22).**
  Znalezione na żywo: pve9 miał 15 zakolejkowanych zdarzeń od poprzedniego dnia
  i `alert-digest` w **zerowej** liczbie crontabów. Nikt nie zawinił z osobna.
  Zasada jest słuszna — jeden digest na host, wykonuje root, czyta kolejkę,
  do której piszą OBA konta, a konto delegowane musi opt-outować, bo
  `alert-digest.sh` celowo nie jest mu kopiowany. Ale linię emitował
  `gen-cron.sh` **wewnątrz bloku relacji i tylko gdy ten blok miał monitory**,
  więc na hoście, którego jedyna relacja żyje na koncie delegowanym, jedyna
  strona uprawniona do zaplanowania digestu nigdy nie była pytana, a pytana
  słusznie odmawiała. Granica, nie błąd w linijce — i flota idzie w tę stronę
  od migracji root→konto delegowane.
  Digest przeniesiony do bloku `zfs-backup-host` w `deploy.sh`, obok kontroli
  pojemności i auto-pulla, instalowany przez **adopt** (ręcznie przestawiony
  harmonogram przeżywa; przenoszona jest tylko LOKALIZACJA linii). To zamyka
  też drugą połowę tej samej granicy: pve1 miał linię **dwa razy** — rezydualnie
  w bloku hosta ze starszego deploya i wygenerowaną — czyli dwa uruchomienia
  o 07:00 ścigające się o ten sam plik kolejki.
  `digest_script` jest nadal parsowany (istniejące configi nie pękają), ale nie
  ma już linii do stłumienia. Host dostaje linię przy najbliższym uruchomieniu
  `deploy.sh` (każda zmiana relacji je odpala).
  **Okno bez digestu jest teraz głośne (2026-08-23).** Do tej pory był to cichy
  obowiązek ręczny: `gen-cron.sh --install` przepisuje blok, stara linia digestu
  z niego znika, a nowej nie ma nigdzie, dopóki ktoś nie odpali `deploy.sh`.
  **To okno zostało zamknięte 2026-09-02.** Przez cały czas opisany niżej
  wdrożeniem był godzinny `git pull`, a **nie** godzinny `deploy.sh`, więc okno
  było realne i nieograniczone — host kolejkował znaleziska i nie wysyłał nic,
  nie mówiąc o tym ani słowa. Dokładnie w tym stanie pve9 spędził miesiące.
  Od 2026-09-02 udana zmiana rewizji **sama się wdraża**: `update-control.sh`
  po fast-forwardzie uruchamia `deploy.sh`, więc skrypty generowane z jego
  heredoców idą za checkoutem. Okno zamyka się w ciągu godziny, a nie „kiedy
  ktoś sobie przypomni".
  `--install` **ostrzega** teraz wprost, gdy usuwa linię digestu ze starego bloku,
  i podaje lekarstwo (`./deploy.sh` na tym hoście). Ostrzeżenie, nie odmowa:
  linia odchodzi zgodnie z projektem, a blokowanie pierwszej instalacji na każdym
  hoście byłoby gorszą awarią. Kontrola negatywna w suicie: blok bez digestu
  instaluje się cicho.
- **Kontrakt, który wskazuje test, nie zastępuje krawędzi, która go uruchamia
  (2026-08-23).** `cron2conf` padał **10 przypadków na opublikowanym `main`** i nikt
  tego nie widział. `aa66674` wyprowadził linię digestu z bloku gen-cron.sh, przez
  co fikstury round-tripu przestały opisywać dzisiejszy kształt — a `[file:gen-cron.sh]`
  w grafie wpływu nie wymieniał suity `cron2conf`, więc CI nigdy jej nie wybrało.
  Kontrakt `cron-line-shape` **od początku** mówił, że `cron2conf.sh` czyta wyjście
  `gen-cron.sh` jako sztywny literał, i jego `check` wskazywał właśnie te fikstury —
  ale kontrakt każe czytelnikowi spojrzeć, niczego nie uruchamia. Wyszło dopiero, gdy
  niezwiązana gałąź przypadkiem wybrała tę suitę. Krawędź dopisana; fikstury
  `fixtures/` opisują dzisiejszy kształt, `fixtures-legacy/` **zachowują** linię
  digestu (bo hosty naprawdę ją mają), a harness dowodzi wprost, że nie jest odtwarzana.

- **Martwe łącze nie może już powiedzieć „nie ma tu rodziny" (2026-08-22).**
  Dwie sondy odpowiadały na pytanie o ŹRÓDŁO statusem, który znaczył też
  „nie dało się zapytać". `source_family_exists` sprowadzało
  `ssh | grep | sort | tail | cut` do tekstu albo pustki, a puste znaczyło
  „brak rodziny" — i miejsce wywołania w seedzie czyta brak rodziny jako
  zgodę na seed **aktywny**, stemplujący snapshoty na źródle. Zmierzone na
  żywym łańcuchu z działającą kontrolą pozytywną: ten sam dataset z rodziną
  przy padniętym hoście dawał tę samą odpowiedź co dataset bez rodziny. Tak
  zaczyna się szkoda LAB6-F4 — środek łańcucha przestemplowany, drabinka jego
  właściciela kasuje własną bazę, pull wiesza się na odmowie GUID.
  Bliźniaczo `has_committed_scope` (`ssh "test -s …"`) mieszało „nie ma
  sidecara" (rc 1) z „nie ma łącza" (rc 255), a `has_committed_scope || return 0`
  znaczy „brak podpisu → zostaw starą listę datasetów": awaria transportu
  po cichu cofała relację z kontraktu THE SIGNED SCOPE IS THE CONTRACT (#101)
  do zapisanej listy. Obie sondy są teraz **trójstanowe** (jest / nie ma /
  nie dało się zapytać), a wszystkich pięciu konsumentów ma jawną gałąź
  „nie wiem": trzy odmawiają (decyzja o pasywności, seed, final-catchup),
  próba generalna aktywacji raportuje własne `UNKNOWN (passive)` zamiast
  cudzego „no snapshot reachable", a `resolve_mode_datasets` odmawia zamiast
  wracać do starej listy. Testy 68a–68e są **behawioralne** (stub `ssh` per
  funkcja, prawdziwe funkcje), z kontrolą pozytywną i negatywną — 67c/67c2
  pinują kształt, 68 pinuje zachowanie.

- **Wdrożenie sync przestało prosić źródło o podpis pod całym majątkiem
  (2026-08-22, LAB6 pass 7 F-1).** `--source=HOST:DATASET --mode=sync` nazywa
  dataset, ale enrolment go gubił: gałąź `if mode = sync` dokładała `--mode=sync`
  i porzucała `$dataset`, więc wsad parowania szedł z `PEER_CONF_DATASETS=""`,
  a `--draft-scope` na źródle szkicował z ciszy — czyli cały majątek. Zmierzone
  na żywo: enrolment nazywający `hdd/lab6chain` wyprodukował na pve1 sekcję
  AKTYWNĄ (tę, z której nadaje `--commit-scope`, nie zakomentowany inwentarz)
  obejmującą `hdd/vm-disks` — 5.39T produkcji, w tym `subvol-101`, czyli bramę
  OpenVPN — oraz `rpool/data`. Następny krok, który narzędzie samo drukuje, to
  „uruchom `--commit-scope` na źródle".
  Pakiet mode-based niesie teraz `PEER_CONF_REQUESTED` — to, co kolektor
  NAZWAŁ — a szkic domyśla sekcję aktywną do tego. **To nie jest druga lista
  datasetów:** listę, którą sync replikuje, nadal ustala to, co źródło
  ZATWIERDZI; zmienia się to, co dostaje do podpisu. `validate_peer_conf`
  odmawia REQUESTED bez MODE i REQUESTED razem z DATASETS, klucz zapisywany
  jest tylko gdy jest żądanie (starszy kolektor paruje się bez zmian), a bare
  `add-client --mode=sync` — który naprawdę nic nie nazwał — dalej dostaje
  szkic całego majątku. Dowód na żywo: 7 stanz → 1, inwentarz nadal pod spodem,
  `--commit-scope` nadał 6 datasetów podrzewa i zero produkcji.

- **Lista poprawek pokampanijnych P1–P10 zamknięta; P10 dowiedziony na żywo,
  a żywe hosty znalazły TRZY wady po zielonym CI (2026-08-21).**
  Zamknięte: P5 (sync brał więcej niż zamówiono — `assert_sync_scope_within_request`
  plus bezwarunkowe logowanie rozwiązanej listy; **to była bramka za grantem, nie
  zamiast niego** — stronę szkicu zamknęło dopiero F-1 z 2026-08-22 wyżej), P6 (edytor zakresu przez
  `ssh -t` bez terminala), P7 (relacja wycelowana we własny host przechodziła
  planowanie), P8 (`remove-client` zabierał wspólny rekord parowania),
  P9 (nagrobek twierdził, że dane przeżyły, nie sprawdzając), P10
  (`migrate-profile` i `audit-source-retention` nie umiały wybrać relacji).
  Przy okazji wyciągnięta **warstwa decyzyjna** `cron_context_resolve` — jedno
  miejsce odpowiadające „który config i jako kto". Powód jest mierzalny: crontab
  ma **jednego** pisarza, który trzyma zamek i walidację, więc jego ~18
  zleceniodawców nie ma jak się rozjechać; config miał **pięciu** pisarzy, zero
  zamków i pięć własnych warstw decyzyjnych.

  **P10 dowiedziony na `8b55e2a`, oba kierunki, na trzech hostach**, kod wyjścia
  mierzony bez potoku. pve2 i pve1 (root = lab z `jobs.<host>.conf`, `zfsbackup`
  = produkcja z `jobs.<host>.v4.conf`): bez celowania `rc=1` i odmowa nazywająca
  **oba** bloki; `--local-user=root` → `rc=0` i config laba; `--local-user=zfsbackup`
  → `rc=0` i config produkcji. pve9 (bez żadnego bloku) nie zapala fałszywego
  alarmu — mówi wprost, że nie ma configu.

  **Trzy wady znalezione przez żywy host już PO zielonym CI** — to jest właściwy
  wniosek z tego etapu, nie sama lista:
  1. `cron_known_accounts` czytało wyłącznie nasze rekordy, więc odmowa **nie
     zapaliła się na hoście, na którym wadę zmierzono**. Uzasadnienie („konto
     istnieje z powodów niezwiązanych z projektem, katalog domowy nie czyni go
     naszym") było słuszne — **przesłanka nie**: produkcja na tej flocie nie
     trafiła do konta przez relację, jest starsza od modelu relacji. Test 64h
     **przypinał martwe pole**, co jest gorsze niż brak testu. Naprawione
     spoolem crontabów jako trzecim źródłem kandydatów, filtrowanym naszym
     własnym znacznikiem bloku — więc obce konto nie może zostać przywłaszczone.
  2. `--local-user=root`, czyli **recepta, którą sama odmowa drukuje**, wpadała
     z powrotem w tę odmowę: parsery zerowały dosłowne `root` do `""`,
     nieodróżnialnego od „nic nie podano". Strażnik odrzucający własną receptę
     jest gorszy niż brak strażnika — zatrzymuje pracę *i* myli co do wyjścia.
  3. Bramka terminala P6, wpisana na sztywno, **skasowała własne pokrycie
     testowe**: w CI nigdy nie ma tty, więc trzy ścieżki edytora przestały być
     testowane. Wyciągnięta do `have_terminal()`, którą suite podmienia, wraz
     z kontrolą pozytywną i asercją, że podmiana nie kłamie o tym, co zastępuje.

  We wszystkich trzech kod, test i komentarz zgadzały się ze sobą i myliły
  **razem**. Dwa razy mylił się też sam pomiar, **zanim** pomylił się kod:
  `rc` czytane przez `| head` raportowało status `head` (czyli `0` dla odmowy —
  gdyby to była prawda, byłaby to znacznie gorsza wada, bo `die` z zerem
  pozwala każdemu wołającemu iść dalej), a oczekiwanie sondy dla pve9 było
  błędne, nie zachowanie narzędzia. **Oczekiwanie sondy jest hipotezą i wymaga
  uzasadnienia tak samo jak wynik.**

- **Trzy pauzy przetestowane na żywo; twarda pauza była NIEMOŻLIWA (2026-08-20).**
  Pauza zadania (`deploy.sh --pause`), miękka pauza relacji (`pause-client`)
  i twarda pauza relacji (`disable-client`) sprawdzone po kolei na metropolis.
  Wszystkie trzy działają — ale dopiero po naprawie, bo `disable-client` padał:
  katalog stanu u peera odziedziczył grupę `zfsalert` przez bit setgid rodzica
  zamiast dostać grupę konta bramy, więc zapis `disabled.new` kończył się
  `Permission denied`. Udowodnione z kontrolą pozytywną (`touch` jako
  `zfsbackup-pve1` → odmowa, jako `zfsbackup` → rc=0) i domknięte naprawą:
  po `chown root:zfsbackup-<peer>` twarda pauza przeszła od razu, a ręczny
  `snapget` **bez** `-L` wrócił `PAIR_DISABLED`.
  **Właściwe znalezisko jest jednak w kodzie, nie w uprawnieniach.**
  `gate_state_dir_ok` wykrywał ten stan poprawnie, ale komunikat opisywał
  **odwrotną** konsekwencję — „disable still WORKS ... enable will refuse" —
  a to na tym przekonaniu opierała się decyzja, żeby tylko ostrzec i pozwolić
  enrolmentowi dojść do końca. Oba czasowniki piszą do **katalogu** (disable
  tworzy marker, enable go kasuje), więc katalog bez prawa zapisu kosztuje całą
  bramę, nie samo zdjęcie blokady. Komentarz odnotowuje, że ten sam objaw
  widziano na pve2 w 2026-08-06: powtórzył się, był ostrzegany, a ostrzeżenie
  zaniżało wagę. Komunikat mówi teraz prawdziwą konsekwencję.
  Poprawione przy tej samej okazji: `status` nie pokazywał blokady u peera
  i wprost zapewniał, że nieoznaczone komendy nie są blokowane — nieprawda
  w momencie, gdy peer odmawiał wszystkiego; teraz odpytuje bramę i raportuje
  `DISABLED`/`NIEZNANA` osobno od pauzy lokalnej. `pause-client` mówił „managed
  jobs now exit SKIPPED", choć retencja jest zarządzana i **chodzi dalej** —
  linie `delsnaps` nie mają `-L` (silnik nie zna tej flagi), także ta tnąca po
  źródle; skutek ogranicza drabinka GFS, ale twierdzenie było fałszywe.
  Szczegóły: `docs/LAB4-OBSERWACJE.md` O8–O17, procedura w
  `docs/LAB-RUNBOOK.md` §9.
- **PRZYCZYNA twardej pauzy znaleziona i usunięta: rekurencyjny `chgrp`
  rozbrajał ją na całej flocie (2026-08-20).** Wcześniejsza poprawka dotyczyła
  **komunikatu**; przyczyna została i wróciła przy pierwszej odbudowie relacji.
  `deploy.sh:3173` robiło `chgrp -R "$ALERT_GROUP" "$ALERT_SHARED_DIR"`, czyli
  zamiatało grupę rekurencyjnie po `/var/lib/zfs-snapshot-all` — w tym po
  `relationships/<etykieta>/`, które celowo ma grupę konta danej relacji.
  Zmierzone eksperymentem, nie wywnioskowane: ustawiam katalog poprawnie,
  uruchamiam **zwykły** `bash deploy.sh` bez flag, po nim grupa to znów
  `zfsalert`. **Każde** uruchomienie `deploy.sh` — również przy `--join`,
  `--leave`, `--commit-scope` i samoaktualizacji — rozbrajało twardą pauzę
  wszystkich relacji na hoście, więc naprawa ręczna trzymała się do najbliższego
  przebiegu. To gorsze niż brak mechanizmu: operator jest przekonany, że go ma.
  Zamiatacz zachowuje swoje zadanie i przestaje wchodzić w poddrzewo, którego
  nie jest właścicielem (`alert_dir_chgrp`, `find -prune`). `test/pairgate` +3,
  w tym kontrakt przez nieobecność gołego `chgrp -R`.
  **Flota naprawiona 2026-08-20, jednorazowo i trwale.** `chown
  root:zfsbackup-<peer>` wykonany na pve2 (`pve1`) i pve9 (`pve1`, `pve2`),
  a trwałość **sprawdzona**: po naprawie uruchomiony prawdziwy `deploy.sh` na
  obu hostach z nowym kodem i grupa została. Przegląd całej floty (pve0 i pve1
  z 11.x, pve1/pve2 metropolis, pve9) nie pokazuje już żadnego katalogu bramy
  ze złą grupą. Nowe relacje wychodzą poprawne same.
  Przy okazji usunięty osierocony `relationships/pve0` na **11.x pve1** —
  pusty, bez konta, bez manifestu, bez klucza i bez linii crona, pozostałość po
  dwuhostowym dowodzie RUX z 2026-08-16, którego rozbiórka pominęła ten katalog
  (ta sama luka, którą opisuje O13). Jedyne wystąpienia `pve0` w żywym configu
  produkcyjnym to komentarze, `pair_label` nie występuje tam wcale. Świadomie
  **bez** `deploy.sh --leave=pve0`: bez manifestu i tak by odmówił, a po drodze
  wykonałby pełne wdrożenie na produkcyjnym hoście z `vsql2`; usunięte przez
  `rmdir`, który sam odmówiłby przy niepustym katalogu. Zapis w
  `/root/orphan-relationships-pve0.<timestamp>/` na tym hoście.
- **Odmowa bramy przestała udawać awarię wdrożenia — i fałszywy alarm o puli
  zniknął (2026-08-20).** Silnik dostawał wprost `PAIR_DISABLED: relationship
  ... is disabled by administrator`, a raportował „exit 93 — e.g. no 'zfs' in
  this account's PATH". Poprawka w `lib-zfs-snap.sh` (rozmrożenie autoryzowane
  z góry przez właściciela, wpis w `ENGINE-FREEZE.md`), więc objęła oba silniki.
  Kod wyjścia `93` jest kontraktem `zfs-pair-gate.sh`, tekst potwierdzeniem.
  **Najgroźniejsze było trzecie miejsce:** `pool_health` wyrzucało kod wyjścia,
  odmowa spadała na `UNKNOWN`, a `check_pool_health` wysyła mail na wszystko,
  co nie jest `ONLINE` — czyli blokada administracyjna podnosiła alarm o stanie
  dysków dla zdrowej puli. Teraz `PAIR-DISABLED`, wyjaśnienie i **zero alertu**;
  od „relacja przestała kopiować" jest `check-snap-age`.
  Przy okazji naprawiony błąd zakresu w obu funkcjach z cache: klucz budowany
  wewnątrz tego samego `local`, które deklaruje wejścia, rozwija się z zakresu
  **zewnętrznego** — nieustawiony pod `set -u`, a z cudzą wartością, gdy taka
  zmienna istnieje. Działało wyłącznie przypadkiem dzięki dynamicznemu zakresowi
  u jedynego wołającego; stawką jest klucz cache, więc zły klucz przechodzi
  między pulami. Semantyka transferu nietknięta.
  `test/quiesce` +11 testów, sprawdzonych jako padające na zamrożonej bazie.
- **Usunięta przyczyna, nie łata: `read_server_conf` przestało kasować cudzy stan
  (2026-08-21).** Właściciel zapytał wprost, czemu wdrożenie jednoserwerowe idzie
  innym kodem niż dwuserwerowe i nazwał to łataniem. Pomiar przyznał mu rację
  w miejscu głębszym, niż sam wskazał.
  Sama **instalacja jest wspólna** — obie ścieżki wołają te same dziewięć
  pomocników (cztery asercje, transakcja, `cron_target_user`, `crontab_for_target`,
  `default_cron_config`, `read_server_conf`). Rozjeżdża się **warstwa decyzji**
  nad nimi, i każdy rozjazd dał dziś osobny błąd.
  Najgłębszy: `read_server_conf()` ustawiało `LOCAL_USER=""` — a `setup-server`
  zapisuje do `server.conf` **dokładnie dwa pola** i `LOCAL_USER` nie jest jednym
  z nich. Czyli ładowarka kasowała zmienną, której wczytywany plik **nigdy nie
  zawiera**: pozostałość po czasach, gdy konto było ustawieniem hosta. Gdy projekt
  przeszedł na decyzję per relacja, usunięto zapis, a czyszczenie zostało.
  `cmd_activate_client` i `cmd_remove_client` **obchodziły** to, każde własnym
  odtworzeniem wartości — i te dwa obejścia sprawiały, że zachowanie wyglądało na
  zamierzone. Trzeci wołający nie wiedział i dostał błąd. Dwa obejścia i jeden
  błąd to koszt złamania zasady, że **ładowarka nie czyści stanu, którego nie jest
  właścicielem**. Czyszczenie usunięte, moja własna łata razem z nim.
  Druga duplikacja: gramatyka nazwy konta istniała w **trzech kopiach** różniących
  się tylko prefiksem błędu (`setup-server`, `add-client`, `local-backup`) —
  trzecią dopisałem wczoraj, kopiując drugą, i tak samo odziedziczyłem brakujące
  odtworzenie `LOCAL_USER`. Jedna funkcja `local_user_name_valid` zamiast trzech.
  `test/localbackup` +3, w tym asercja, że ładowarka zostawia `LOCAL_USER`
  w spokoju — ta jedna linia złapałaby wczorajszy błąd.
- **Wdrożenie jednoserwerowe przyjmuje `--local-user` (2026-08-21).** Do tej pory
  mogło chodzić **tylko jako root**, i to nie z projektu, tylko z przeoczenia:
  parser formy lokalnej odrzucał flagę (`unknown option --local-user=...`),
  `setup-server --local-user` tworzył konto ale go nie zapisywał — słusznie, bo
  konto jest decyzją **per wdrożenie**, nie ustawieniem hosta — a
  `cron_target_user` bez `LOCAL_USER` zwracał roota. Zmierzone na pve9: konto
  powstało, blok i tak wylądował u roota.
  Cała maszyneria pod spodem była już świadoma konta (`cron_target_user`,
  `crontab_for_target`, `assert_config_readable_by_target`,
  `atomic_replace_and_install`). Brakowało wyłącznie flagi. Zrobione **spójnie
  z formą zdalną**: ta sama nazwa, ta sama gramatyka nazwy konta, ten sam
  domyślny root z tym samym zdaniem, konto tworzone gdy brak, blok do crontaba
  tego konta.
  Dwie rzeczy musiały wejść razem, bo bez nich delegacja byłaby pozorna:
  podgląd renderował się przez `bash $GENCRON` (kopia roota), a instalacja przez
  `gencron_as_target` (kopia konta) — `gen-cron` wypieka ścieżki z miejsca, gdzie
  leży, więc podgląd pokazywałby blok, który nigdy nie powstanie; oraz delegacja
  ZFS musi objąć **każde źródło i cel**, a cel przed seedem jeszcze nie istnieje,
  więc jest tworzony jawnie i wąsko, zamiast delegować rodzica i oddać kontu pulę.
  **Plan nie tworzy konta.** Pierwsza wersja tworzyła — a plan ma kontrakt
  „installs nothing", i konto uniksowe nim nie jest. Pod `--install` powstaje,
  przy planie odmowa: `gen-cron` nie miałby czym wyrenderować prawdziwego bloku,
  a pokazanie cudzego jest gorsze niż odmowa. `test/localbackup` +5.
- **`gen-cron.sh --uninstall` — właściciel bloku umie go wreszcie zdjąć (2026-08-20).**
  Znalezione przy przechodzeniu macierzy wdrożeń na pve9: backup **lokalny**
  (jeden host, `--source`/`--target`, bez peera) instaluje blok zarządzany,
  którego **nic nie potrafiło usunąć**. `remove-client` wymaga relacji;
  `clean-relationships.sh` słusznie mówi, że to nie relacja; opróżniony config
  jest odrzucany (`no send/prune/monitor rules resolved`); `cron_block_remove`
  istnieje w bibliotece, ale osiągalne jest wyłącznie przez `remove-client`.
  Pakiet potrafił zbudować coś, czego nie potrafił rozebrać.
  Czasownik nie wymaga `-c`, i to jest sedno: typowym powodem sięgnięcia po
  niego jest to, że config **już zniknął** albo jest zły — żądanie configu
  odmawiałoby dokładnie wtedy, gdy jest najbardziej potrzebny. Zakres to blok
  i nic więcej: config i datasety są **nazwane i zostawione**, ta sama postawa
  co `remove-client` wobec `known_hosts` i `clean-relationships.sh` wobec danych.
  Komunikat mówi wprost „removed the SCHEDULE, not the backups", bo „odinstalowane"
  obok datasetu pełnego kopii to zdanie, które operator odczyta źle.
  Dołożony brakujący strażnik `flock`: bez niego brak programu wychodził
  z biblioteki jako „another writer is holding it", czyli wysyłał operatora
  na poszukiwanie procesu, którego nie ma. `test/localbackup` +6.
- **NOWE NARZĘDZIE: `clean-relationships.sh` — audyt i usuwanie śladów po
  relacjach (2026-08-20).** Powstało z dzisiejszej rozbiórki: dwa istniejące
  czasowniki (`remove-client`, `deploy.sh --leave`) robią swoje dobrze, ale
  żaden nie odpowiada na pytanie **„co po relacjach zostało na TYM hoście"** —
  a ręczne odpowiadanie na nie zawiodło dwa razy tego samego dnia.
  Kodowane jest w nim to, co okazało się sednem trudności: **jedna relacja ma
  na dysku do trzech tożsamości** — nazwę (rekord klienta, `-L` w cronie),
  adres (`peers/<addr>.conf`, cztery pliki klucza, rusztowanie joinu) i etykietę
  (`peers/<label>.conf`, `relationships/<label>/`, konto `zfsbackup-<label>`).
  Sprzątanie kluczowane na jednej z nich **musi** przegapić resztę; stąd dwie
  asymetrie, dla których to narzędzie istnieje: `peers/` jest kluczowane
  dwojako i `remove-client` usuwa tylko wariant po adresie, oraz dokładnie
  jeden z czterech plików klucza (`_alias_known_hosts`, ten podawany do `-k`
  w liniach crona) przeżywa usunięcie.
  Domyślnie **tylko czyta** i wychodzi z kodem 3, gdy znajdzie sieroty.
  Usuwanie wymaga jawnego `--purge=`/`--purge-orphans` **i** `--yes`; wszystko,
  co zaklasyfikowane jako LIVE, jest odmawiane; kolejność jest wymuszona
  w kodzie (`deploy.sh --leave` **przed** ręcznym sprzątaniem, bo manifest jest
  jego mapą); katalogi znikają przez `rmdir`, który sam odmawia przy niepustym;
  `known_hosts` nietknięty, komenda `ssh-keygen -R` wypisana, nie wykonana;
  crontaby wszystkich kont hashowane przed i po, z raportem.
  Konto `zfsbackup` bez sufiksu jest jawnie wyłączone — to konto własnych zadań
  hosta, nie relacja. `test/cleanrel` 13/13, w pełni w piaskownicy.
- **NAPRAWIONE tego samego dnia, obie drogi (decyzja właściciela).** `deploy.sh`
  woła zdalny join jako `timeout "$PEER_REMOTE_JOIN_TIMEOUT" ssh -n ...`: `-n`
  daje zdalnemu odczytowi EOF od razu, więc `--join` kończy się swoją własną
  porażką — tą, dla której gałąź awaryjna została napisana; `timeout` (300 s)
  jest drugim ograniczeniem na zator niezwiązany z wejściem, a jego brak też
  wpada w tę samą gałąź zamiast wisieć. Zator jest raportowany osobno od odmowy.
  Druga droga: `rux_grant_remotely_preflight` sprawdza kanał root-ssh **i**
  manifest joinu na źródle, **zanim** powstanie konto, rekord klienta, klucze
  i wsad — bo bez joinu nie istnieje konto, do którego grant miałby trafić.
  Przy okazji domknięta ta sama choroba obok: komentarz obiecywał „refuse EARLY,
  before any state changes", a funkcja była wołana po `cmd_add_client`.
  Regresje: `joinremote` 8–9, `rux` 25–28, sprawdzone jako **padające na kodzie
  sprzed poprawki**; `rux` 26 jest kontrolą pozytywną.
- **ZNALEZIONE: `--grant-remotely` wieszało się na parze, która NIE jest jeszcze
  sparowana (2026-08-20).** Wykryte przy wdrożeniu od zera na sterylnych hostach:
  jedna komenda stanęła na ponad sześć minut bez żadnego komunikatu. Zmierzone:
  `deploy.sh --join` na peerze siedział w `wchan=pipe_read`, `stdin=pipe:`.
  `--join` pyta o akceptację zakresu i **celowo** nie ma `--yes`; puszczony przez
  ssh bez terminala nie ma jak dostać odpowiedzi, a nic go nie ogranicza czasowo.
  Sedno: wołający **już** toleruje nieudany join i ma tor awaryjny
  (`zfs-backup.sh:3357`) — ten tor nigdy się nie włącza, bo wywołanie nie wraca.
  To **nie jest fail-open**: po zakończeniu zdalnego procesu tor awaryjny zadziałał,
  a enrolment dokończył się poprawnie z grantem zatwierdzonym na źródle.
  Poprawka jest zmierzona, nie wyrozumowana — uruchomienie z `</dev/null`
  sprawiło, że zdalny `--join` dostał EOF i tor awaryjny włączył się dokładnie
  jak zaprojektowano. **Do decyzji właściciela**, bo dotyka granicy bezpieczeństwa:
  (1) ograniczyć czas i zamknąć wejście zdalnemu `--join`, (2) `--grant-remotely`
  sprawdza sparowanie przed startem i odmawia od razu, (3) rozszerzyć audytowaną
  zgodę na akceptację zakresu. Skłaniam się do (1)+(2).
  **Koryguje wcześniejszy wpis o `--grant-remotely`** niżej: flaga działała, ale
  tamta para hostów była już sparowana, więc krok, który się wiesza, wtedy się
  nie wykonał. „Od zera" było nieprawdą.
  Obejście na dziś: na niesparowanej parze użyj drogi domyślnej, dwustronnej
  (`--install` → `deploy.sh --join=` na peerze → `--commit-scope=` na źródle →
  powtórz `--install`). Przeprowadzona tą drogą 2026-08-20: `rc=0`, zero `!!!`.
- **Wdrożenie od zera bez błędów, po pełnej rozbiórce (2026-08-20).** Łańcuch
  `pve9 → pve2 → pve1` rozebrany do zera i zbudowany ponownie **tymi samymi
  nazwami relacji** — niepełna rozbiórka rozbiłaby się o terminalny stan
  `removed`, więc to jest jednocześnie dowód jej kompletności. md5 zgodne na
  wszystkich trzech skokach, drugi skok `rc=0` bez jednej linii `!!!`.
  Produkcja nietknięta na obu kolektorach: crontab konta `zfsbackup` identyczny
  bajt w bajt, zero grantów na `hdd/vm-disks`, `hdd/backups`, `rpool/data`
  i `rpool/ROOT`. Skryptu „usuń pakiet i wszystkie ślady" nadal **nie ma**
  (`clean_all` zaplanowany); taksonomia tego, co zostawiają `remove-client`
  i `--leave`, zmierzona i spisana w `docs/LAB4-OBSERWACJE.md` O13 wraz
  z pełną kolejnością w `docs/LAB-RUNBOOK.md`.
- **`--pause`/`--resume` przestały być wdrożeniem (2026-08-20).** Wysyłka leżała
  pod wszystkimi innymi trybami, więc okno serwisowe wykonywało najpierw całe
  wdrożenie: **dziewięć faz**, zmierzone z prawdziwego przebiegu. Dwie z nich
  piszą linie crona, a `lib-cron.sh` słusznie odmawia zapisu do zapauzowanego
  bloku — więc `--resume` ogłaszał „this host would stop picking up updates"
  osiem linii przed poprawnym wznowieniem. Strażnik działał, alarm był fałszywy;
  to jest ta kombinacja, która uczy operatora przewijać `!!!`.
  Cała rodzina `do_pause*`/`do_resume*` przeniesiona ponad fazy (bash nie zna
  funkcji zdefiniowanej niżej, więc sam `if` nie wystarczał), po sprawdzeniu, że
  blok woła tylko `log`/`warn` i `lib-cron.sh`. Zmierzone na żywo na pve9 przez
  worktree na gałęzi, checkout główny nietknięty na `main`: log z **61 linii na 4**,
  **z 9 faz na 0**, `--resume` z **dwóch `!!!` na zero**, oba crontaby po pełnym
  cyklu identyczne bajt w bajt.
  Przy okazji naprawiony kontrakt testowy: `test/pause` kończyła wycinanie kodu
  na komentarzu, który *przypadkiem* stał zaraz za rodziną funkcji, więc po
  przeniesieniu wciągnęła resztę pliku i padła na `PAUSE_MODE: unbound variable`
  daleko od przyczyny. `deploy.sh` ma jawny terminator, suita odmawia wprost przy
  ponownym przekroczeniu, a kontrola pozytywna (skasowany terminator) potwierdza,
  że nowa bramka faktycznie strzela.
- **`--grant-remotely` i `--join-remotely` dopisane do pomocy; enrolment z 4 komend na 1 (2026-08-20).**
  Przemiał przełączników objął `deploy.sh` i `gen-cron.sh`, a **pominął
  `zfs-backup.sh`** — moje niedopatrzenie. Kryły się tam dwie działające flagi
  bez wpisu w pomocy, w tym ta, która skraca całe wdrożenie relacji.
  Domyślna ścieżka to **cztery wykonania** (plan → install, staje na grancie →
  `--commit-scope` na źródle → install ponownie) i jedno obejrzenie szkicu.
  To jest projekt, nie niedoróbka: grant jest decyzją strony źródłowej.
  `--grant-remotely` to jawna, audytowana zgoda na podjęcie jej zdalnie —
  **jedna komenda zamiast czterech**. Zmierzone na labie, nie przeczytane z kodu:
  `--source=192.168.28.99:hdd/lab4/src2 --target=hdd/lab4direct --name=lab4-direct
  --grant-remotely --install --yes` przeszło od zera do `STATE=active`, a md5
  `ec156c1e6a665a919a85148e5bec56ed` zgodne ze źródłem. Log potwierdza własności,
  które ta flaga miała trzymać: zakres zbudowany **z linii poleceń** (`1 dataset(s)
  granted, 0 revoked, 0 held back`), audyt zapisany na źródle, zwykła weryfikacja
  wykonana po fakcie. **Pierwsze uruchomienie tej ścieżki na żywo.**
  Ważne, czego to NIE zmienia: cztery poprawki z laba **nie skróciły niczego** —
  naprawiły to, że komunikat mówi prawdę o brakującym kroku. Redukcja istniała
  przez cały czas w niewidocznej fladze. Dokładnie ten problem, który opisałem
  słowami „przełącznik, który działa i którego nie da się znaleźć, jest gorszy
  niż jego brak" — i przegapiłem go, bo nie przemiotłem tego jednego pliku.
- **ZNALEZIONE PRZY OKAZJI: pve9 ma inną strefę czasową niż flota.** Narzędzie
  ostrzegło samo: pve1 `+0200`, pve9 `+0000`. Nazwy snapshotów tworzonych na pve9
  niosą inny czas niż reszta floty, a `restore --plan` zgłosi to jako rozjazd
  nazwa↔`creation`. Nie ruszone — to zmiana na hoście, nie w kodzie.
- **LAB4 na metropolis: łańcuch pve9 → pve2 → pve1 dowiedziony, cztery błędy znalezione i naprawione (2026-08-20).**
  Pierwszy pełny lab na dzisiejszym kodzie. Dane 12 MB przeszły dwa skoki, **md5
  zgodne co do bitu na wszystkich trzech hostach**. Produkcja nietknięta — sprawdzone
  na obu kolektorach: zero delegacji kont labowych na `hdd/vm-disks`, `hdd/backups`,
  `rpool/data`, `rpool/ROOT`; granty wyłącznie na liściach lab4; produkcyjne crontaby
  (pve2 12 zadań, pve1 16) na osobnych kontach i configach, bez zmian.
  **BŁĄD 1 — `cron_lock_files_repair` nigdy nie działał przy prawdziwym wdrożeniu.**
  `deploy.sh`: definicja w gałęzi `--check-only`, wywołanie w gałęzi `else`. Commit
  `2f69c2d` z 7 sierpnia — **trzynaście dni**. Naprawa dotyczy pliku blokady 0644,
  który zamyka konto delegowane przed jego własnym crontabem: zmierzone na TRZECH
  Z CZTERECH hostów produkcyjnych 2026-08-07. Żadna suita tego nie widziała, bo
  suity wyciągają funkcje sedem — u nich definicja istnieje zawsze. Obie funkcje
  przeniesione na poziom pliku.
  **BŁĄD 2 — wznowienie przeskakuje krok, który padł.** Ze stanu `pending_enroll`
  ponowienie tej samej komendy **nie ponawia joinu** (log wznowienia: dwie linie,
  zero prób) i wywala się na pobraniu zakresu komunikatem „czy `--draft-scope` już
  tam chodził?" — kierując operatora na zły problem. Komunikat rozdzielony po
  MANIFEŚCIE peera: jego brak znaczy join, jego obecność znaczy draft. Plan
  lifecycle mówi teraz wprost, że ponowienie joinu nie ponawia. Automatyczne
  ponawianie joinu ŚWIADOMIE niezrobione — `cmd_add_client` odmawia istniejącemu
  klientowi, więc to przepisanie ścieżki parowania, nie poprawka komunikatu.
  **BŁĄD 3 — stan `removed` raportowany jako „unknown".** Wpadał w gałąź domyślną
  i odsyłał do `status/seed/activate`, z których żaden nie odnawia usuniętej relacji
  — a nic innego w drzewie też nie. Ma teraz własny przypadek mówiący, że jest
  terminalny, i wskazujący `--name=NOWA` jako drogę do ponownego backupu tego peera.
  **BŁĄD 4 — okazał się NIE być błędem.** Seed stempluje `automated_daily_`, a
  monitor pilnuje `automated_hourly`. Zgłosiłem to jako niespójność; po przemyśleniu
  jest odwrotnie: seed nazwany `automated_hourly_` byłby świeżym pasującym snapshotem
  niezależnie od tego, czy godzinowy job kiedykolwiek ruszy — czyli najnowsze, co
  widziałby monitor, byłoby artefaktem enrolmentu, nie dowodem działającego
  harmonogramu. Drabinka GFS kasuje po `automated_`, więc seed i tak podlega
  retencji. Udokumentowane w miejscu wywołania zamiast „naprawione".
  Test `resolve_mode_datasets` rozdzielony na dwa przypadki — stary pinował jeden
  komunikat na dwa różne stany, bo kod ich nie odróżniał.
- **Siedem działających przełączników dopisanych do `--help` (2026-08-20).**
  Przemiał przełączników przed labem. Znalezione: dziewięć flag jest parsowanych
  i w pełni działa, a nie ma ich w pomocy — czyli jedynym sposobem, żeby je
  znaleźć, było przeczytanie źródła.
  `deploy.sh`: `--self-update`, `--rollback`, `--resume-updates` (maszyna stanu
  aktualizacji; `--rollback` na produkcyjnym hoście *musi* być w pomocy),
  `--join-check` (podgląd tego, co zrobiłby `--join`, bez zmiany czegokolwiek),
  `--add-quiesce` (wariant scalający grant quiesce zamiast nadpisującego — bo
  `--join` nadpisuje świadomie).
  `gen-cron.sh`: `--reconcile` (READ-ONLY porównanie „co config backupuje" vs
  „co istnieje"; odpowiada na realną awarię — gość utworzony po napisaniu configu
  chodził z zerem snapshotów) i `--migrate-recursion` (jednorazowa migracja
  starego zapisu rekursji w `flags`).
  `--dump-fields` i `--internal-legacy-render` **zostają ukryte** — są ukryte
  celowo i mają to opisane w kodzie.
  To odwrotność redukcji i tak było zamierzone: przełącznik, który działa, ale
  jest niewidoczny, jest gorszy niż jego brak — istnieje i czeka, aż ktoś go
  odkryje. Suity: gencron 78/78, join 83/83, selfupdate 28/28, reconcile 47/47.
  **Reszty przełączników NIE ruszam przed labem.** Zmierzone: w 82 liniach
  wygenerowanych z czterech produkcyjnych configów silniki dostają sześć flag
  (`-m -v -q -u -r -e`) z ~35. To nie znaczy „29 do wyrzucenia", tylko
  „29 nieprzećwiczonych przez obecną flotę" — te configi są w większości lokalne,
  więc `-A` (dokładane tylko dla zdalnego dst), `-L`, opcje SSH i filtry nie mają
  jak się pojawić. Lab z pullem, relacjami i zdalnymi ścieżkami jest tym, co je
  przećwiczy; cięcie teraz byłoby cięciem w ciemno.
- **ENGINE-FREEZE nazwane tym, czym jest: pieczęcią, nie zamkiem (2026-08-20,
  decyzja właściciela).** Bramka pilnuje pięciu plików silnika, porównując wpis
  indeksu z linią bazową. Jedyną żywą furtką jest `--refreeze`, którą może
  uruchomić każdy — ścieżka „autoryzująca recenzja" wymaga recenzenta, a tego
  zniesiono 2026-08-15. Rozważono zaostrzenie (reset, którego implementer nie
  może scommitować) i **odrzucono**: widoczność jest tym, co realnie płaci —
  obie dzisiejsze zmiany silników zostały w PR-ach nazwane zmianami silnika,
  słowami „contract narrowing on a frozen file", **dokładnie dlatego, że ta
  bramka kazała to powiedzieć**.
  Zmienione: (1) dokument prowadzi teraz żywą ścieżką (kierunek właściciela +
  `--refreeze` + **wpis na liście**), a wersja recenzencka jest oznaczona jako
  uśpiona maszyneria, nie usunięta; (2) komunikat odmowy w `impact.sh` przestał
  odsyłać do nieistniejącego procesu — bramka, która odmawia i wskazuje na
  proces, którego nie ma, czyta się jak błąd narzędzia, nie jak pytanie o zmianę.
  **Wpisem jest mechanizm, nie resetem.** `--refreeze` to jedna komenda, więc to
  nie ona czyni zmianę widoczną — czyni ją wpis. Refreeze bez wpisu to dokładnie
  ta cicha zmiana silnika, której bramka ma zapobiegać.
  Uzupełnione uczciwie: **moje dwa dzisiejsze refreeze nie były na liście**.
  Dopisane, z zaznaczeniem, że ŻADEN nie był autoryzowany z góry — #61
  (zawężenie kontraktu `check-snap-age.sh`) wyszedł z przemiału sprzątającego
  z mojej inicjatywy, właściciel dowiedział się w tej samej wiadomości, która
  go dowoziła. Lista jest nic niewarta, jeśli notuje tylko wygodne przypadki —
  tym bardziej że `check-snap-age.sh` trafił na listę zamrożonych właśnie za
  zawężenie zatwierdzonego kontraktu (REV-20260808-070 F1).
- **Mapa redukcji domknięta: reszta to duplikacja ŚWIADOMA, brakowało jej opisu (2026-08-20).**
  Trzy pozycje ze skanu duplikacji NIE nadają się do scalenia i nigdy nie
  nadawały — brakowało im wyłącznie uzasadnienia w miejscu, którego wymaga własna
  konwencja tego repozytorium (każda inna celowa kopia je nosi, więc kopia bez
  opisu czyta się jak przeoczenie, które ktoś powinien „naprawić").
  **`trim()`** w `cron2conf.sh` i `gen-cron.sh` — bajt w bajt, ale `cron2conf.sh`
  jest wdrażany samodzielnie i **niczego nie sourcuje** (zweryfikowane), więc ma
  tę samą strukturalną przyczynę co kopia `HOLD_TAG` w `delsnaps.sh`. Opis dodany
  po obu stronach, bo para musi być widoczna z obu końców; kluczowe: cron2conf
  czyta to, co gen-cron emituje, więc rozjazd definicji „przycięcia" to cichy
  koniec round-trippingu.
  **Tabela konwersji `<N>m/h/d`** w trzech kopiach — podwójna WALIDACJA była już
  udokumentowana, powielona TABELA nie. `check-snap-age.sh` trzyma dwie z nich,
  jest samodzielnym monitorem i plikiem zamrożonym, więc trzy kopie zostają;
  dopisana reguła, że GRAMATYKA jest jedna — dodanie jednostki musi trafić we
  wszystkie trzy, inaczej próg akceptowany przez generator monitor odrzuca o 3 nad ranem.
  **`config_datasets`** — bez callera produkcyjnego po usunięciu migrate, ale
  **nie martwa**: to przetestowana definicja konwencji dzielenia scope'u, którą
  `assert_no_overlapping_policy` powtarza inline, odwołując się do niej po nazwie
  w komentarzu. Skasowanie zostawiłoby konwencję z implementacją inline i bez
  testu. To ten sam kształt co bliźniaki snapsend/snapget: jedna reguła, dwie
  implementacje, pilnowana jedna. Właściwa naprawa — żeby planer ją WOŁAŁ zamiast
  powtarzać — jest zmianą w planerze, więc należy do laba. Oznaczone w kodzie,
  żeby następny przemiał martwego kodu jej nie usunął.
- **Preambuła skryptów alertowych pisana RAZ zamiast trzy razy (2026-08-20).**
  `deploy.sh` generuje trzy samodzielne skrypty na hoście — `notify-fail.sh`,
  `notify-warn.sh`, `alert-digest.sh` — i wklejał do nich **tę samą 28-liniową
  preambułę** (snapshot zmiennych środowiskowych, wyszukanie configu, `_restore_env`)
  trzema osobnymi kopiami w jednym pliku. Zmierzone: kopie były bajt w bajt
  identyczne. Te skrypty faktycznie nie mogą sourcować wspólnej biblioteki, więc
  tekst MUSI wystąpić w każdym z trzech — ale `deploy.sh` nie musi go nieść
  trzykrotnie. Koszt starego kształtu jest konkretny: poprawka reguły „środowisko
  bije config" (a to jest reguła, przez którą test kiedyś zjadł PRODUKCYJNĄ
  kolejkę alertów) musiała trafić w trzy miejsca albo trzy skrypty zaczynały się
  różnić tym, który pokrętek wygrywa.
  Teraz jedna zmienna `ALERT_ENV_PREAMBLE`, interpolowana w trzy miejsca.
  **−84 / +55 linii.** Zdefiniowana **niecytowanym** heredokiem świadomie: każdy
  `$` w ciele jest zapisany jako `\$`, bo jest przeznaczony dla generowanego
  skryptu, a niecytowany heredoc rozwiązuje to escapowanie w momencie definicji —
  zmienna trzyma dosłowny `$`, a rozwinięcie parametru nie jest rekurencyjne,
  więc przy wstawianiu nic nie rozwija się drugi raz. Heredoc CYTOWANY nie byłby
  równoważny: zostawiłby backslashe i wypuścił `\${ZFS_ALERT_MODE:-}` do skryptu.
  Dowód, nie założenie: wyrenderowane **wszystkie trzy** skrypty przed i po —
  108/60/151 linii, **zero różnic** w każdym. Kontrola pozytywna: preambuła jest
  obecna w każdym renderze. Kontrola negatywna: z pustą zmienną render ma 81 linii
  zamiast 108 i 29 różnic, więc tożsamość nie jest pusta. Pierwsza wersja tego
  pomiaru dawała „0 linii vs 0 linii, 0 różnic" — pusty pass przez złe
  dopasowanie w awk; poprawiony, bo taki wynik to nie dowód. Suita `alertmail` 20/20.
- **Alarm dryfu bliźniaków domknięty: 8 → 12 pilnowanych funkcji (2026-08-20).**
  `test/twins/run.sh` deklaruje o sobie regułę: *„Keep this list exhaustive
  rather than curated: a name that exists in both and is NOT watched here is the
  one place drift gets to happen unobserved"*. **Nie była wyczerpująca.** Zmierzone:
  dwanaście funkcji zdefiniowanych pod tą samą nazwą w obu silnikach, pilnowanych
  osiem. Brakowały `translate_long_options`, `opt_takes_arg`, `cluster_needs_next`,
  `declare_recursion` — dziś bajt w bajt identyczne (46/3/11/4 linii, zero różnic),
  co jest zarazem powodem, dla którego łatwo je przeoczyć, i powodem, dla którego
  późniejszą rozbieżność trudno byłoby zauważyć.
  Kontekst, bo bez niego wygląda to na argument za scaleniem: **scalenie silników
  zostało ROZWAŻONE I ODRZUCONE 2026-08-04** (wpis niżej w tym pliku) — parametr
  kierunku zawodzi OTWARCIE przy wykrywaniu wspólnej bazy, a `test/snapsend` jest
  LOCAL MODE ONLY, więc suita, która miałaby to złapać, strukturalnie nie może.
  Tamta decyzja wybrała **alarm zamiast scalenia**, więc dziura w alarmie była
  dziurą w decyzji, nie argumentem przeciw niej. Te cztery nie niosą kierunku
  w ogóle, i to też nie czyni ich kandydatami do `lib-zfs-snap.sh`.
  Linia bazowa: dokładnie 4 dopisane wiersze, ósemka nietknięta; każda z czwórki
  ma identyczny skrót po obu stronach, co niezależnie potwierdza identyczność.
  Kontrola: przed blessem suita czerwieni się na nowych nazwach (lista jest realnie
  konsultowana), po — **38 PASS / 0 FAIL** (było 30). Oba silniki dostały nagłówek
  `THE TWIN` z odsyłaczem do decyzji; zmierzone, że komentarz nagłówkowy nie
  narusza pinowanych skrótów. ZAMROŻENIE: linia bazowa przejęta przez `--refreeze`,
  zmiana to wyłącznie komentarze.
  Osobno warte zapamiętania: `translate_long_options` niesie komentarz *„a
  hand-kept list is a list that drifts, and a drift here is silent"* — sam będąc
  ręcznie trzymaną drugą kopią, której nic nie pilnowało.
- **Martwy kod usunięty: −278 linii, w tym zahardkodowana polityka po Slice B1 (2026-08-20).**
  Drugi krok redukcji. Trzy skupiska, wszystkie potwierdzone brakiem callerów
  w kodzie ORAZ w testach (lekcja z usuwania migrate: testy pinują dosłowne
  linie źródła, nie tylko nazwy funkcji):
  **(1) Zahardkodowane szablony, 93 linie** — `STANDARD_TEMPLATE_*` /
  `KEEP_TEMPLATE_*` plus listy nazw. Sam plik pisał obok: *„Until B1 the policy
  above lived in shell variables in this file. It now lives in `profiles/<name>/`,
  and this is the only place that reads it"* — hardcode był świadomie zastąpiony
  i po prostu został. Sprawdzone też pod kątem indirekcji `${!var}` (jedyne jej
  użycia dotyczą endpointów, nie szablonów).
  **(2) `HOST_NAME/TAIL/BEGIN/END` + `set_host_block`, 49 linii** — pozostałość
  po usunięciu `migrate-to-account` (2026-08-19). Blok `zfs-backup-host` ŻYJE,
  ale jego pisarzem jest `deploy.sh` (`CRON_HOST_BLOCK`); kopia w `zfs-backup.sh`
  służyła wyłącznie migracji. Komentarz w `lib-cron.sh` twierdzący, że ten blok
  należy do `zfs-backup.sh`, poprawiony.
  **(3) `QCAP_VALUE_FLAGS` + `job_positionals`, 42 linie** — resztka po tym samym
  usunięciu (prefiks `QCAP_` to podsystem capability-survey).
  Do tego sekcja 21 w `test/zfsbackup` (89 linii), która testowała (2), oraz
  nieaktualna nota „Slice A: fixture only" w `profiles/default/templates.conf` —
  wraz z przeniesieniem tam wiedzy o `retain=` zamiast `keep=` (REV-20260730-001),
  która ginęła razem z usuwanym komentarzem. Naprawiona też biała lista
  `.gitignore`: `profiles/` nie było na niej wcale, więc jego pliki były śledzone
  tylko dlatego, że git już o nich wiedział — ta sama pułapka, którą komentarz
  o `deploy.sh` dwie linijki wyżej opisuje.
  Suity: `profiles` 55/55, `gencron` 78/78, `cron` 137/137; `zfsbackup` 302 PASS
  / 0 FAIL zanim lokalny limit uciął (pełny przebieg ~34 min — w CI).
- **`assert_block_runnable_by` to BRAKUJĄCE WYWOŁANIE, nie martwy kod (2026-08-20).**
  Funkcja istnieje, nie ma ani jednego callera, a `docs/discussions/DEPLOY-PRECONDITIONS.md`
  opisuje ją jako **[JEST]** — aktywny warunek wstępny. Powstała po awarii na
  metropolis pve2 2026-08-01: config odbudowany przez `cron2conf.sh` niósł
  `[defaults] repo_dir` z rootową ścieżką, `/root` ma 0700, więc każda linia bloku
  kończyła się `exit 126` — a idiom crona kończy się `rm -f "$e"`, więc **każda
  raportowała rc=0** i host nie miał działającego backupu. Sąsiedni warunek
  `assert_config_readable_by_target` jest wołany w 5 miejscach; ten w zerowej.
  Nie usunięto i nie podpięto: podpięcie to zmiana zachowania na ścieżce instalacji
  crontaba i należy do testów na labie, nie do sprzątania.
- **Ledger recenzji przestał być bramką merge'a (2026-08-20).** Pierwszy krok
  redukcji aparatu procesu. `test/impact.sh --verify` wołało
  `test/reviewctl.sh --verify`, a `--verify` jest wymaganym checkiem `graph`
  w CI — więc spójność `docs/internal/reviews/` była **warunkiem merge'a**.
  `HANDOFF.md` zniósł protokół recenzji 2026-08-15 („No reviewer. No REV files,
  no REVIEW_LEDGER.md routing"), czyli przez pięć dni bramka pilnowała procesu,
  którego nikt nie prowadził — aparat przeżywający własne zniesienie to dokładnie
  ta awaria, którą tamten reset miał zakończyć. Skala: **28 142 linie** artefaktów
  recenzji (127 REV + 119 odpowiedzi), czyli tyle, co CAŁY produkt (28 556).
  Ukryty koszt: ten check był **jedynym** powodem, dla którego zadanie `graph`
  potrzebowało `fetch-depth: 0` — CI klonowało pełną historię repozytorium, żeby
  zwalidować archiwum. Teraz klonuje płytko. Zadanie `suites` zachowuje pełną
  historię, bo selektywne CI nadal diffuje `base...HEAD`.
  **NIC NIE USUNIĘTO.** `reviewctl.sh` bajt w bajt nietknięty, wszystkie 127 REV
  i 119 odpowiedzi na miejscu — decyzja właściciela: to historia projektu i
  znika, jeśli w ogóle, na końcu. Zmieniło się tylko to, że przestało warunkować
  merge; `./test/reviewctl.sh --verify` działa na żądanie. Wywołanie usunięte,
  nie schowane za flagą: bramka domyślnie wyłączona to bramka, którą ktoś
  przypadkiem włączy z powrotem.
- **`check-snap-age.sh` odmawia pustego wzorca (2026-08-20).** ZAWĘŻENIE KONTRAKTU
  na pliku ZAMROŻONYM — patrz nota o linii bazowej niżej. Dopasowanie to
  `[[ "$snapname" == "${PATTERN}"* ]]`, więc pusty wzorzec łapie KAŻDY snapshot
  na datasecie, także cudzy. Na Proxmoksie to nie jest zbiór teoretyczny: pvesr
  trzyma własny `__replicate_<job>_<epoch>__` i odświeża go w rytmie replikacji,
  vzdump zostawia swoje. Zmierzone na żywo na pve2, ten sam dataset, ta sama chwila:
  `pattern=automated_hourly` → `newest=automated_hourly_2026-08-20_05-37-01 age=3h`,
  `pattern=` (pusty) → `newest=__replicate_107-0_1787198451__ age=2h`. Czyli pusty
  wzorzec podał wiek o godzinę MŁODSZY, mierząc cudzy snapshot; gdyby nasza rodzina
  stanęła całkowicie, taki monitor raportowałby OK tak długo, jak długo chodzi pvesr.
  Monitor, który nie może się zaczerwienić, jest gorszy niż jego brak — zajmuje
  miejsce działającego i czyta się jak dowód zdrowia. Nie ma przypadku użycia
  „pilnuj czegokolwiek": każdy caller nazywa rodzinę, którą posiada, a `gen-cron.sh`
  tego kształtu nie potrafi nawet wyemitować (`require_field` odrzuca pusty
  `pattern` wszędzie, gdzie monitor powstaje). Zamknięte dla wywołań RĘCZNYCH,
  które nagłówek tego skryptu sam każe pisać dla zdalnego scope'u.
  Wyjście `UNKNOWN` (3), nie WARNING/CRITICAL: żaden snapshot nie został jeszcze
  zbadany, więc każda odpowiedź o świeżości byłaby zmyślona — a generowana linia
  crona kieruje `rc>=3` na `notify-fail` jako „monitor BROKEN", czym taki monitor
  dokładnie jest. Live-proven na pve2 2026-08-20: pusty → rc=3 z komunikatem,
  właściwy wzorzec → rc=2 CRITICAL bez zmian. Linia bazowa zamrożenia przejęta
  przez `--refreeze` (brak recenzenta w obecnym reżimie; reset jest widoczny w diffie).
- **Próg monitora konfrontowany z własną kadencją tieru (2026-08-20).**
  Ostatnia z pięciu dziur gramatyki configu, jedyna wymagająca nowej maszynerii.
  Monitor mierzy wiek najnowszego pasującego snapshotu: zero tuż po runie,
  a tuż przed następnym — dokładnie przerwę między runami. Więc `monitor_warn`
  nie większy niż najdłuższa przerwa alarmuje na **zdrowym** jobie co cykl i nigdy
  na prawdziwej awarii. Tier dobowy z `monitor_warn = 90m` przy `monitor_schedule`
  `*/15` to ~76 maili dziennie na dataset — to nie prognoza, to incydent
  384-maili-na-noc, trafiony na tej infrastrukturze trzy razy. Obie liczby są
  w ręku generatora, więc odmowa idzie tutaj.
  Maksymalna przerwa liczona przez przejście PRAWDZIWEGO kalendarza (okno
  2028-2029, więc luty przestępny i zwykły), arytmetycznie, bez `date(1)` —
  731 procesów na tier byłoby nie do przyjęcia w generatorze, który ma być
  natychmiastowy; wynik cache'owany per wyrażenie. Dzięki temu weekly to 7 dni,
  monthly 31 (najdłuższy miesiąc, nie średnia), a `* * * * 1-5` to 72 h przez
  weekend — wartości, których naiwne „popatrz na pole, które wygląda na interwał"
  nie daje. Porównanie jest z DOLNYM ograniczeniem prawdziwej najgorszej przerwy
  (zaobserwowana przerwa jest przerwą rzeczywistą), co gwarantuje brak fałszywych
  odmów; harmonogram o mniej niż dwóch odpaleniach w oknie (np. `0 0 29 2 *`)
  jest pomijany, nie zgadywany. Sprawdzane WYŁĄCZNIE tam, gdzie ten sam tier
  wysyła i monitoruje — `[prune:]` i dataset bez `send_schedule` pilnują rodziny
  przychodzącej skądinąd i ich kadencji w tym pliku nie ma.
  Zasięg: 6 produkcyjnych configów v4 + 4 przykłady bez zmian; kontrola pozytywna
  — `jobs.pve1.v4.conf` z `monitor_warn` obniżonym z 30h do 20h jest odrzucany.
  Fixture'y: `test/negative/monitor-below-cadence`, golden `test/fixtures/monitor-cadence-ok`.
- **Pola harmonogramu walidowane składniowo (2026-08-20).**
  `send_schedule`, `prune_schedule`, `monitor_schedule` i `schedule`
  w `[prune-bookmarks:]` szły dotąd do crontaba niesprawdzone. `send_schedule = 0 2 *`
  dawało rc=0 i generowało `0 2 * echo "$(date -Is) ZFS-JOB BEGIN ..."` — cron
  czyta pierwsze tokeny komendy jako pola miesiąca i dnia tygodnia. SZEŚĆ pól jest
  gorsze niż trzy: komenda zaczyna się wtedy od gołej `*`, którą shell rozwija po
  plikach w katalogu roboczym joba i uruchamia to, co dostanie. Jedyną bramką był
  `crontab(1)` przy `--install` — najpóźniejszy możliwy moment, po drugiej stronie
  granicy hosta, i odrzuca CAŁY crontab, więc jedna zła linia kładzie dobre.
  Teraz: dokładnie 5 pól, każde w zakresie. Skróty `@daily`/`@reboot` celowo
  NIEPRZYJMOWANE — `cron2conf.sh` i `job_identity` czytają wygenerowaną linię
  zakładając pięciopolowy prefiks. Kontrola per pole jest permisywna wobec
  STRUKTURY (listy, zakresy, kroki, trzyliterowe nazwy miesięcy i dni przechodzą)
  i ścisła tylko wobec alfabetu i zakresów liczbowych — walidator, który wymyśliłby
  ograniczenie nieistniejące w cronie, odrzucałby działający config, co jest gorszą
  awarią niż dziura, którą zamyka. Zasięg: 6 produkcyjnych configów v4 + 4 przykłady
  bez zmian. Fixture'y: `test/negative/cron-field-count`, `test/negative/cron-out-of-range`.
- **Pola yes/no na `[prune:]`/`[prune-bookmarks:]` czytane ściśle (2026-08-20).**
  `recursive`, `clear_cut`, `gfs` i `prune` były porównywane z literałem `"yes"`
  po trim+lowercase, więc KAŻDA inna pisownia — łącznie z literówką i wartością
  pustą — po cichu znaczyła „nie", przy rc=0 i wyglądającym sensownie bloku.
  `recursive = ture` zamieniało zadeklarowany sweep poddrzewa w pojedynczy
  dataset: wszystkie dzieci przestawały być kasowane, a jedynym śladem była linia
  `delsnaps` bez `-R`. `gfs = ture` zamieniało jedną kaskadową drabinę w N płaskich
  linii per tier — to inny kształt retencji, nie mniejszy. `[dataset:] recursive`
  jest fatal-on-unknown od REV-20260807-054 („an unrecognised value is fatal
  rather than falsy"); to są sekcje, do których tamta reforma nie dotarła.
  Teraz dozwolone wyłącznie `yes`/`no` (dowolna wielkość liter), puste = błąd.
  Walidator komunikuje się globalną i jest wołany BEZ `$(...)` — `die` w
  podstawieniu poleceń ubija tylko podpowłokę i zostawia skrypt na rc=0 z cicho
  porzuconą wartością (ta sama pułapka, którą opisuje komentarz przy
  `lint_autotune`). Zasięg: 6 produkcyjnych configów v4 + 4 przykłady z
  `docs/examples/` bez zmian.
  Fixture'y: `test/negative/bool-typo`, `test/negative/bool-blank`.
- **Allow-list pól `gen-cron.sh` zgodzona z rzeczywistymi miejscami odczytu (2026-08-20).**
  Nagłówek sekcji allow-listy od początku deklarował „the lists mirror the
  resolve_field/require_field/ini_has call sites" — i to było nieprawdą w OBIE
  strony. **Przyjmowane, nieczytane:** cały `POLICY_FIELDS` szedł hurtem do każdego
  rodzaju sekcji, a realne lookupy są węższe. `monitor_warn`/`monitor_crit`
  w `[defaults]` dawało rc=0 i ZERO linii `check-snap-age` (`resolve_monitor`
  czyta sekcja→template i kończy) — operator pisał „pilnuj wszystkiego" na górze
  pliku i nie dostawał żadnego monitoringu, czego z definicji nic nie zgłosi, bo
  brakującym elementem JEST zgłaszanie. `flags` w `[defaults]` gubione tak samo,
  więc `flags = -w` na górze pliku po cichu nie zmieniało tego, co leci po drucie.
  Gwardia „nieznane pole" tego nie łapie — nazwa jest poprawna, nieczytana jest
  POZYCJA. **Czytane, nieprzyjmowane:** `build_prune_section` rozwiązuje
  `gfs_pattern` z warstwą `defaults`, ale allow-list odrzucała tam to pole, więc
  ta warstwa była kodem nieosiągalnym; teraz działa (host z jedną drabiną na kilka
  sekcji `[prune:]` pisze prefiks raz). Listy rozbite per rodzaj sekcji; usunięte
  pozycje: `[defaults]` — keep/retain/tier_label/notify*/monitor_warn/monitor_crit/
  flags; `[dataset:]` — notify_word/notify_raw_prune (czytane tylko z template);
  `[prune:]` — send_schedule/prefix/dst/src/autotune/quiesce/flags/notify_raw
  (sekcja prune nigdy nie wysyła; połączenie zdalnego scope konfiguruje `ssh_flags`).
  Listy zostają RĘCZNE i jest napisane dlaczego: scraper wymiaru „warstwa" musiałby
  wiedzieć, w której funkcji-builderze siedzi call site, a pomyłka dawałaby FAŁSZYWE
  odrzucenie działającego configu. Zasięg zmierzony: wszystkie 6 produkcyjnych
  configów v4, wszystkie 4 przykłady z `docs/examples/`, cały golden set i pola
  emitowane przez `zfs-backup.sh` — bez zmian.
  Fixture'y: `test/negative/defaults-monitor`, `test/negative/prune-transfer-field`,
  golden `test/fixtures/gfs-pattern-defaults` (dowodzi, że dziedziczona wartość
  faktycznie dociera do linii `-G`, nie tylko że config się parsuje).
- **`gen-cron.sh` odmawia drabiny GFS, która nie widzi zasilających ją tierów (2026-08-20).**
  Druga dziura z tej samej rodziny co niżej, w `[prune:]` z `gfs = yes`. Każdy
  tier z `use_template` oddaje drabinie literę kubełka i licznik (`-H24 -D7 -W4`),
  ale drabina dopasowuje po JEDNYM `gfs_pattern` — a `delsnaps.sh` matchuje po
  prefiksie. Dotąd `gfs_pattern = zabbix_` przy tierach `automated_*` przechodziło
  z rc=0: licznik tierów szedł na cudzą rodzinę, `automated_*` nie kasował nikt,
  a monitor każdego tieru — czytający dalej swój własny, wąski `pattern` — świecił
  na zielono, bo świeże snapshoty faktycznie przychodziły. Wersja za wąska
  (`gfs_pattern = automated_hourly` przy tierach hourly/daily/weekly) tak samo.
  Teraz: `pattern` KAŻDEGO zasilającego tieru musi zaczynać się od `gfs_pattern`.
  Sprawdzane tylko dla tierów, które realnie zasilają drabinę — `prune = no` niesie
  sam monitor i drabinie nic nie oddaje. Pominięty `gfs_pattern` (drabina
  prefixless z Fazy 3.5) to `""`, prefiks wszystkiego, więc przechodzi bez
  przypadku szczególnego. Produkcyjny `[prune:hdd/backups]` na pve2 (`gfs_pattern
  = automated_`, jedyna żywa drabina we flocie) przechodzi; kontrola pozytywna:
  ten sam plik ze zwężonym `gfs_pattern` jest odrzucany.
  Fixture: `test/negative/gfs-pattern-blind`.
- **`gen-cron.sh` odmawia tieru, który tworzy jedną rodzinę snapshotów a kasuje inną (2026-08-19).**
  Czyszczenie semantyki warstwy konfiguracyjnej. Tier mający JEDNOCZEŚNIE
  `send_schedule` i `prune_schedule` musi umieć skasować to, co tworzy:
  `delsnaps.sh` dopasowuje po PREFIKSIE, więc `prefix` musi zaczynać się od
  `pattern`. Dotąd `prefix = automated_daily_` przy `pattern = automated_hourly_`
  przechodziło z rc=0 — każdy send zielony, każdy prune zielony, tyle że prune
  zjadał CUDZĄ rodzinę, a własna rosła bez ograniczenia aż do zapełnienia pool-a.
  To ten sam cichy kształt co REV-20260807-054 i realnie powstaje przez
  copy-paste między tierami (zmieniony `prefix`, niezmieniony `pattern`).
  Teraz twardy błąd w czasie generowania. Guard jest **per-tier** (flaga zerowana
  na każdy tier, bo `prefix` żyje w gałęzi send) i **nie** dotyczy przypadku
  prefixless z Fazy 3.5 (`prefix` → `""`: nazwy pochodzą z góry, `-e`/bare
  timestamp), ani sekcji `[prune:]`, które z definicji sprzątają cudzą rodzinę.
  Porównanie literalne (`${p:0:${#pattern}}`), nie `case`-em — arm `case`
  globuje wzorzec i przepuściłby dokładnie te configi, których guard pilnuje.
  Sprawdzone przeciw wszystkim 6 produkcyjnym configom v4 (`jobs.11.11`,
  `jobs.pve0` ×2, `jobs.pve1`, `jobs.pve2`, `lab.pve0-remote-dst`) — wszystkie
  nadal rc=0; kontrola pozytywna: zmutowany `jobs.pve1.v4.conf` jest odrzucany.
  Fixture: `test/negative/prefix-pattern-mismatch`.
- **Martwy wrapper `cron_replace_all` usunięty (2026-08-19).** Po usunięciu migrate stracił jedynego callera. `cron_replace_all_impl` (realna praca: read/F4-markers/write) ZOSTAJE — `deploy.sh` woła go wprost w trybie batch (wiele bloków pod jednym lockiem). Wrapper dodawał tylko lock/unlock. Test `cron` sekcja T repointowana na `_impl` (pełne pokrycie T1-T9 zachowane; lock testowany osobno w sekcji U).
- **Czasownik `migrate-to-account` USUNIĘTY (2026-08-19).** Sprzątanie narośli
  komend. Był to jednotransakcyjny root→konto **host-wide** przenoszący cały blok
  crona hosta na jedno konto (5 faz REV-020). Zadanie spełnione — flota zmigrowana
  2026-08-01, zero operacyjnych callerów — i **semantycznie niespójny** z modelem
  per-relacja z #48: przenosił crontab host-wide, ale nie tykał `LOCAL_USER` w
  rekordach klientów, więc następny `activate` cofnąłby migrację. Usunięto: verb +
  dispatch + usage, cały **podsystem capability-survey** (`capability_survey`,
  `capability_remediation` i 7 building-blocków `qcap_*`/`block_*`/`qscope_*`/
  `target_can_*` — istniał wyłącznie dla preflightu migrate), oraz 13 sekcji
  `test/zfsbackup`. Prymityw `cron_replace_all` (lib-cron) ZOSTAJE (generyczny,
  stracił jedynego callera — flaga: caller-less). Guard `assert_no_foreign_managed_block`
  ZOSTAJE, jego komunikat przekierowany na ścieżkę per-relacja (`remove-client` +
  redeploy) zamiast na usuwaną komendę. Historyczny runbook
  `docs/MIGRATION-ROOT-TO-ACCOUNT.md` oznaczony WYCOFANE.
- **`--source=HOST:` (deferred scope) zbudowany; czasownik `deploy` zretirowany (2026-08-19).**
  Sprzątanie narośli komend. `deploy NAME --host=` i `--source=HOST:DATASET` robiły
  ten sam lifecycle (`deploy_continue_lifecycle`, wspólny), ale `deploy` był formą
  **deferred-scope** (źródło proponuje draft, operator wybiera), a `--source=`
  wymagał jawnego datasetu. Teraz `--source=HOST:` (pusty dataset) robi deferred:
  `rux_split_source` dopuszcza pusty dataset, `rux_remote_install` pomija
  `--datasets` (add-client defer-uje do draftu), dodane `--manual-join`. `deploy`
  (funkcja `cmd_deploy` + dispatch + usage) **usunięty** — `deploy.sh` (skrypt
  bootstrapu pakietów: pigz/exim/mbuffer/apt/konta) NIETKNIĘTY, to inny byt.
  `test/rux` przepisany: sekcja 20 na model konta z #48 (dług, który #48 zostawił —
  rux nie jest required-check), + testy deferred (11b–e). **Zredukowano warstwę
  jednopoleceniową z dwóch form do jednej.**

- **Konto to jawny wybór per-relacja; bez `--local-user` = root (2026-08-19).**
  Owner decision + refaktor. Usunięta cała magia rozwiązywania konta: adopcja
  (`rux_detect_local_user`), zapis host-wide do `server.conf` (`rux_record_local_user`,
  `RUX_DEFAULT_LOCAL_USER=zfsbackup`) i odmowa „puste conf = dwuznaczne". Nowa
  reguła: `--local-user=NAME` deleguje na DOWOLNE konto (root/zfsbackup/bkp,
  tworzone jeśli brak), **pominięcie = root**, koniec. Decyzja jedzie Z RELACJĄ
  (manifest `PEER_SAVED_LOCAL_USER` + nowe pole `LOCAL_USER` w rekordzie klienta),
  więc activate/remove ją odczytują, nie zgadują. `server.conf` traci pole konta
  (zostają `DEFAULT_TARGET`+`CRON_CONFIG`, wyprowadzalne); `setup-server --local-user`
  tylko tworzy konto (bootstrap), nic nie zapisuje. `zfs-backup.sh` −123 linie.
  Suita `zfsbackup` 446/446 (żywe pve0), Batch B + sekcja 61 przepisane na nową
  semantykę.

- **`remove-client` rozbiera relacje na hoście bez server.conf (2026-08-19).**
  Znalezione na żywo przy teardownie lab3 pve9 (sync/passive, brak server.conf):
  `cmd_remove_client` po `read_server_conf` zostawiał `LOCAL_USER` puste, więc
  `cron_target_user` spadał na roota — a bloki managed żyją w crontabie konta
  delegowanego. `cron_block_remove` czyścił więc crontab ROOTA (no-op), blok
  zfsbackup przeżywał, i `deploy.sh --unpair` odmawiał „dopóki linie działają" —
  kołowo, teardown nie mógł cofnąć tego, co aktywacja zainstalowała jako konto.
  `cmd_activate_client` (strona zapisu) rozwiązywał to z manifestu
  (`PEER_SAVED_LOCAL_USER`); remove-client nie ma manifestu, więc teraz **adoptuje
  konto, które host już ma** (`rux_detect_local_user` = właściciel checkoutu, ta
  sama reguła co deploy.sh/RUX). server.conf dalej wygrywa, gdy przypina; host bez
  konta delegowanego dalej spada na roota. LIVE-PROVEN: pve9 rozebrany czysto —
  managed usunięty z konta, blok `zfs-backup-host` roota (auto-pull) nietknięty,
  klient `removed`, `--unpair` przeszedł.

- **ssh do martwego peera już nie wisi ~130 s (2026-08-19).** ZMIERZONE na żywym
  Linuksie (pve0): `ssh -o BatchMode=yes 10.5.5.5 true` na nierutowalny adres
  wraca `rc=255` dopiero po **129 636 ms** — kernelowy timeout SYN — bo połączenie
  nie miało `ConnectTimeout`. Wszystkie ssh sterujące w `zfs-backup.sh` (delegacja
  `zfs allow`, fetch scope'u, sondy endpointu/catchupu, `PAIR-CONTROL`, kanał root
  rux) sięgają peera, który może być wyłączony, więc każde było ~130 s zamulenia
  crona na martwym hoście; tylko ścieżka `PAIR-CONTROL` miała limit (15 s). Teraz
  jedna stała `SSH_CONNECT_TIMEOUT` (15, env-overridable) + `SSH_SERVER_ALIVE_*`
  (15/4) na wszystkich **9** grupach ssh — martwy peer pada tak samo przy connect
  (ConnectTimeout) jak i gdy zamilknie w trakcie (ServerAlive). To DORÓWNANIE do
  data-plane: `snapsend.sh`/`snapget.sh` już budowały `SSH_OPTS` z tym samym
  kompletem (l. 1830/1813), a `lib-zfs-snap.sh` używa go przy każdym transferze —
  więc transfer był chroniony od początku, tylko sterowanie nie. Niezmienniki
  pinowane: `test/zfsbackup` liczy `BatchMode == ConnectTimeout == ServerAlive`
  dla `zfs-backup.sh`, a `test/twins` sekcja D wymaga ConnectTimeout+ServerAlive
  po OBU stronach silnika (data-plane guard bez roota, bo suita `snapsend` jest
  root-gated i nic w CI inaczej by tego nie utrzymało).

- **Leg CI `zfsbackup`: 34 min → ~34 s (2026-08-19), przyczyna zmierzona, nie
  zgadnięta.** Ta sama ekspozycja co wyżej: garść testów sięgała funkcji SUT
  ssh-ujących BEZ własnego stuba, więc realny `ssh` do fikstur `10.x` wisiał
  ~130 s każdy (instrumentacja `[[SLOW]]`: 5 asercji w sekcjach reaktywacji =
  2027 s z 2059 s). Globalny fast-fail stub `ssh` (natychmiastowe 255, ten sam rc
  co realna porażka; per-test stuby nadal nadpisują na PATH) domyka to bez zmiany
  logiki — zweryfikowane na pve0 (25 s, 446/446) i na CI (leg 34 s vs 2059 s
  baseline). Przy okazji: matryca CI jest teraz **selektywna** — każdy leg pyta
  `impact.sh --suites base…HEAD` i self-skipuje (exit 0), gdy dana warstwa nie
  została ruszona; nazwy required-checków bez zmian (branch protection nietknięte),
  fail-safe pełnej baterii przy zmianie grafu/plumbingu/huba lub pliku spoza grafu
  (`__ALL__`). Asercje suity `zfsbackup` wołają odtąd już zesource'owane funkcje
  w podpowłoce `( )` zamiast re-source'ować cały skrypt przez `bash -c` (37 miejsc;
  na Windows 3,5×/miejsce, na CI pomijalne — bo kosztem był ssh-hang, nie re-source).

- **Kampania lab3 (2026-08-17): łańcuch trzech hostów pve2→(backup)→pve1→(sync)→pve9
  ZBUDOWANY I DOWIEDZIONY na żywo** — pve9 to świeża VM (Debian 12 cloud, VM 109
  na pve2, 192.168.28.99, pula `hdd` 40G), md5+GUID zgodne przez cały łańcuch,
  przyrost (`data2.bin`) przeniesiony wygenerowanymi liniami crona uruchomionymi
  przez prawdziwy cron — z markerami `ZFS-JOB` (pierwsze bojowe użycie; F8 niżej
  został ZAUWAŻONY dzięki nim). Hosty metropolii wyczyszczone ze WSZYSTKICH
  pozostałości testowych przed startem (taksonomia śmieci → wiedza pod
  `clean_all`). Wyłowione i naprawione tą samą kampanią:
  **F1** `rux_verify_requested_scope` porównywał żądanie z manifestem, który sam
  zapisuje żądanie (`PEER_SAVED_DATASETS` powstaje przy `--pair` z `--datasets`)
  — czek nie mógł obleć; teraz weryfikuje względem scope'u ZACOMMITOWANEGO na
  źródle (fetch + sidecar sha256 przez współdzielony `fetch_committed_scope`;
  brak sidecara = odmowa nazywająca czyj ruch: `deploy.sh --commit-scope=…` na
  źródle). Granica „grant nigdy zdalnie" (REV-033 U10) NIETKNIĘTA — odmowa robi
  ją czytelną. **F2** draft scope proponował WSZYSTKIE gałęzie hosta (produkcja
  włącznie), gdy kolektor prosił o jeden dataset — ACTIVE domyślnie = dokładnie
  `PEER_JOIN_DATASETS` z manifestu joina, inwentarz zostaje komentarzem-menu.
  **F3** bez server.conf aktywacja instalowała do crontaba ROOTA i pisała config
  W checkoutcie gita — teraz konto z `PEER_SAVED_LOCAL_USER` manifestu (server.conf
  dalej wygrywa, gdy przypina), a domyślna ścieżka configu to
  `/etc/zfs-snapshot-all/jobs.<host>.conf` (`default_cron_config`, 5 miejsc).
  **F5** tabela zależności nie znała `crontab` — świeży obraz cloud NIE MA crona,
  a "all dependencies present" przechodziło; dodane jako required. **F6**
  ostrzeżenie przy aktywacji, gdy strefy czasowe kolektora i źródła się różnią
  (pve9=UTC vs flota=CEST → nazwy snapshotów kłamią o czasie). **F8** grant
  commit-scope nie zawierał `mount`, a delegacja ZFS wymaga go do DESTROY
  snapshotu (zfs-allow(8)) — źródłowy prune padał co godzinę z `permission
  denied`, które delsnaps ubierał w mylną podpowiedź o klonach; `mount` dodany do
  grantu i unallow przy `--leave`, a hint delsnaps wybierany z PRAWDZIWEGO stderr
  (klony vs delegacja), nigdy bezwarunkowo. Suita `rux` 23/23 po przepisaniu
  testów 17/18 na nowy kontrakt (fetch stubowany PLIKIEM scope, porównanie przez
  prawdziwe `scope_read`/`scope_includes` z lib-scope). **OTWARTE z kampanii:**
  F7 — pve9 tworzy własne snapshoty na datasecie KOPII pve1 (kolektor środkowego
  ogniwa), przeplatając dwie rodziny nazw w jednym prefiksie `automated_`; GFS na
  kopii skasował świeży snapshot ogniwa A trzymając równoległy z ogniwa B —
  topologia łańcuchowa wymaga decyzji projektowej (dyskusja z właścicielem);
  plus dedukcja „wdrożenie WYŁĄCZNIE przez zfs-backup.sh" (bez schodzenia do
  deploy.sh) — ROZSTRZYGNIĘTA: właściciel zaakceptował semantykę
  **`--grant-remotely`** (`docs/project/OWNER-GRANT-REMOTELY-2026-08-17.md`,
  poprawka do U10). Jawna, audytowana zgoda operatora na commit scope'u NA
  ŹRÓDLE tym samym kanałem root-ssh, którego join już użył; scope = ŻĄDANIE
  z konstrukcji, nigdy szerzej; różniący się draft odmawia nawet pod flagą;
  brak kanału odmawia WCZEŚNIE, przed jakąkolwiek zmianą; ślad
  `GRANTED_REMOTELY_BY` w manifeście źródła; weryfikacja (fetch+hash+includes)
  zachowuje swój autorytet PO grancie; default zostaje dwudotykowy.
  `--local-user` przy braku konta tworzy je lokalnie z głośną linią. Suita
  `rux` 27/27 (+4: kolejność grant→verify→seed pinowana jako KOLEJNOŚĆ, nie
  obecność; default bez flagi bez kroku grantu; autorytet weryfikacji po
  grancie — niedopasowany commit odmawia przed seedem; odmowa nadpisania
  cudzego draftu). **F7 ROZSTRZYGNIĘTE I ZAIMPLEMENTOWANE** (właściciel:
  „Działaj"): sync NIGDY nie zakłada drugiej rodziny snapshotów — dataset,
  którego źródło już niesie rodzinę `automated_*`, staje się PASYWNY
  (`snapget -e`): zero nowych snapshotów na źródle, zero prune'a źródła,
  retencja rodziny u jej właściciela; prefix generyczny `automated_`,
  harmonogram przesunięty na :31 (pull w tej samej minucie co producent =
  zmierzona kolizja kubełka GFS), progi monitora 3h/5h pod kadencję
  ŁAŃCUCHA (lekcja próg-vs-kadencja, trzecie wystąpienie); wykrycie per
  dataset przy aktywacji (jedno `zfs list` po załadowanym kanale, działa
  przed grantem), podgląd aktywacji mówi o pasywności GŁOŚNO przed zgodą.

- **REŻIM ZMIENIONY 2026-08-15 — `HANDOFF.md` jest nadrzędny nad `CLAUDE.md`.**
  Recenzenta NIE MA; suity NIE są bramką; testy na żywych hostach dozwolone
  wprost; praca bezpośrednio na `main` (branch/PR gdy tani). Wszystkie wpisy
  niżej, które mówią o recenzencie, `REVIEW_LEDGER.md`, wątkach REV, werdyktach
  „ZAMKNIĘTY przez recenzenta" itd., to **HISTORIA zniesionego reżimu**, nie
  bieżący przepływ — trzymaj je jako zapis kodu/ZFS/infry, nie jako opis
  własności zadań.

- **Konsolidacja 2026-08-15 na `main`** (PR #21 `d14497f`, PR #22 config
  `788c2e0`): jednokomendowa fasada `deploy`, rozwiązywanie konta w `add-client`
  (Batch B), fix wycieku temp-file profilu, matryca CI z `test/deps.conf`, oraz
  szeroki-ale-ograniczony config uprawnień `.claude/settings.json`. Jeden wątek
  na `main`; 22 martwe gałęzie ucięte. **GitHub chroni `main` rulesetem
  `main-protection`** (id 20887546): PR + **10 wymaganych checków** + rozwiązane
  wątki; bezpośredni push (i `HEAD:main`) odrzucony po stronie serwera.

- **RUX — ujednolicony zdalny deploy, LIVE-PROVEN 2026-08-16 (RUX-4 zamknięty).**
  Decyzja właściciela
  `docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md` (MUST DO) była
  niezaimplementowana — `deploy NAZWA --host=X` istniał, ale nie trzymał
  ustalonej gramatyki `--source=/--target=/--mode=`. Teraz ten sam bare entrypoint
  co lokalny backup obsługuje też źródło zdalne:
  `zfs-backup.sh --source=HOST:DATASET --target=DATASET [--install] [--yes]`
  (backup) i `--source=HOST:DATASET --mode=sync` (identity mapping, bez
  `--target`). `rux_entry` w dispatcherze rozstrzyga lokalne/zdalne PRZED tym,
  jak `--source` trafi do jakiegokolwiek parsera — lokalna ścieżka
  (`cmd_local_backup`) jest bit-w-bit nietknięta. Zdalna ścieżka **nie jest
  nowym silnikiem**: składa ISTNIEJĄCY cykl `add-client → seed → activate`
  (wydzielony do współdzielonej `deploy_continue_lifecycle`, używanej też przez
  `cmd_deploy`) i istniejące potwierdzenie zakresu przy `--join`. Nazwa relacji
  domyślnie wyprowadzana z hosta (`peer_label`, `--name=` tylko przy
  niejednoznaczności — zero dodatkowego argumentu w zwykłym przypadku, zgodnie
  z decyzją). `rux_verify_requested_scope` NIE jest drugim mechanizmem grantu —
  tylko SPRAWDZA po `--join`, że to, co źródło faktycznie przyznało, pokrywa to,
  co poproszono, i odmawia z dokładnym powodem zamiast cicho zaakceptować inne
  źródło. Powtórne wywołanie tej samej komendy: rozpoznaje istniejącą relację i
  wznawia (żadnego drugiego `add-client`); sprzeczne fakty (ten sam host, inny
  target/mode) odmawiają zamiast cicho mutować; relacja NIE założona przez RUX
  (brak `RUX_SOURCE`) odmawia zamiast cicho przejąć. Dowód: `test/rux/run.sh`
  23/23 (parser, planner, orkiestracja, konflikt, weryfikacja zakresu — wszystko
  z zaślepionym `deploy.sh`/`seed`/`activate`, bez sieci/ZFS; +2 przypadki
  `--local-user=` znalezione na żywym RUX-4), `zfsbackup` 442/442 bez regresji,
  `localbackup` 55/56 (jedyny fail: `flock` nieobecny w tym środowisku
  Windows/Git-Bash — środowiskowe, niezwiązane z tą zmianą).
  **RUX-4 — żywy dowód WYKONANY 2026-08-16.** Literalny łańcuch trzech hostów
  jest na tej infrastrukturze nieosiągalny (dwa klastry, osobne VPN, brak trasy
  między nimi — potwierdzone `ping`/`ssh`), więc zamiast niego dwa niezależne
  dowody dwuhostowe na throwaway datasetach, oba md5-zgodne i w całości
  posprzątane: backup (pve2-metropolis ← pve1-metropolis) i sync (pve0 ←
  pve1 11.x). Szczegóły i znaleziska w wierszu `rux` tabeli suit niżej;
  `manual:rux-live-chain` w `test/deps.conf` niesie wynik, nie deklarację.

- **`deploy` — jednokomendowe wdrożenie dwuhostowe, LIVE-PROVEN 2026-08-15.**
  `zfs-backup.sh deploy NAZWA --host=ŹRÓDŁO [--target=X] [--profile=P] [--yes]
  [--manual-join]` — cienka, wznawialna fasada spinająca istniejący cykl
  `add-client → seed → activate` (czyta `STATE`, robi tylko brakujące kroki;
  7 przypadków trasowania w `test/zfsbackup/run.sh` sekcja „1c"). Dowód
  end-to-end na metropolis pve1←pve2: throwaway `rpool/deployproof`, izolacja
  (scratch state-dirs + atrapa `crontab` w PATH + przycięty scope do jednego
  datasetu), grant `zfs allow` **additive (0 revoked, `i9a` nietknięta)** i po
  dowodzie **cofnięty**; odebrane dane **md5 bit-w-bit** ze źródłem, realny
  crontab (produkcyjne `i9a`) potwierdzony nietknięty (zapis poszedł do atrapy).
  Domyślny `--join-remotely` NIE był testowany (uruchamia WDROŻONY `deploy.sh`
  na peerze pod hardcoded `REPO_DIR`, nieizolowalny) — dowód szedł
  `--manual-join`. Rdzeń orkiestracji + realna ścieżka danych: dowiedzione.

- **restore (ścieżka BEZPIECZNA) LIVE-PROVEN 2026-08-15** na WDROŻONYM kodzie
  `main`, throwaway, produkcja nietknięta: `restore --plan --config=FILE`
  (read-only; czyta `[dataset:]` relacje, listuje punkty odtworzenia czasem z
  ZFS `creation` NIE z nazwy, i FLAGUJE rozjazd nazwa↔creation) oraz
  `restore --dataset=D --snapshot=S --config=FILE --yes` (`zfs send|recv` do
  unikalnego staging pod `<pula>/restore/`, weryfikacja GUID, `zfs rename` do
  landingu; odmawia gdy landing istnieje, nigdy nie nadpisuje) — **md5
  odtworzonego == źródło, GUID zgodny**. Restore **destruktywny „w miejsce"
  nadal NIE istnieje publicznie** (Faza 7; gramatyka CLI po stronie właściciela)
  — bezpieczny restore mówi to wprost.

- **Restore WYDZIELONY do `zfs-restore.sh` (2026-08-17, decyzja właściciela).**
  Restore to jedyna operacja, której strona aktywna pisze po produkcji —
  odwrotność każdego innego czasownika — więc ta granica zaufania jest teraz
  granicą PLIKU: `zfs-backup.sh` nigdy nie niszczy danych klienta i jest
  odtąd **feature-stable** („wstępnie domknięty" — bugfixy tak, nowa
  funkcjonalność nie; historia review recenzenta pozostaje ważna, bo plik,
  którego dotyczyła, przestał się ruszać). Kod Fazy 7 przeniesiony VERBATIM
  (13 funkcji, linie 3073–4376 starego pliku): planner `--plan`, bezpieczny
  side-restore, wewnętrzny silnik niszczący (nadal bez publicznych drzwi —
  gramatyka CLI i grant kliencki to wiszące decyzje właściciela,
  `docs/design/client-granted-restore.md`). Wspólne helpery (warn/die,
  `SERVER_CONF`+`read_server_conf`, `installed_dataset_field`) przeniesione
  do **`lib-backup-common.sh`** — przeniesione, nie zduplikowane; cięcie
  biegnie po UŻYCIU, nie po nazwach (`managed_source_prefix_for_scope`/
  `source_scope_is_bounded` zostają w zfs-backup.sh — ścieżka audytu).
  Publiczna powierzchnia NIEZMIENIONA: `zfs-backup.sh restore …` forwarduje
  przez `exec` do `zfs-restore.sh`, oba wejścia dowiedzione bajt w bajt
  identyczne. `test/restore` źródłuje odtąd `zfs-restore.sh`; macierz CI
  wyprowadza się z `deps.conf`, więc suita zostaje w CI bez zmian workflow.

- **Restore destruktywny: polityka relacji nad wieloma datasetami — D+B
  (decyzja właściciela, 2026-08-30).** Krok per dataset (`restore_one`) bierze
  JEDEN dataset, a relacja obejmuje ich kilka; nigdzie nie było powiedziane, co
  robi bieg po pięciu, gdy trzeci odpada. Teraz jest to jedno zachowanie
  **biegacza, przez którego przechodzi każda pisząca postać czasownika**
  (`restore_run_scope`):
  **D** — przed pauzą i przed pierwszą mutacją leci pre-flight CAŁEGO zakresu.
  `RESTORE_PREFLIGHT_ONLY=1` przepuszcza `restore_one` przez jego własny
  prefiks — punkt odzysku, strategia, zgoda, odmowy scope-root i
  zamontowanego celu — i zatrzymuje go dokładnie na linii, gdzie kończy się
  czytanie. To **ten sam kod**, nie druga lista odmów. Jeżeli którykolwiek
  dataset odpada, bieg odmawia (kod 2) i wymienia **wszystkie** złe pod
  `UNFIT`, nie pierwszy z brzegu. Przed pauzą świadomie: postawienie żywego
  harmonogramu i zdjęcie go sekundę później dla biegu, który i tak miał
  odmówić, to churn, którego operator potem nie umie wytłumaczyć.
  **B** — wykonanie nie zatrzymuje się na awarii (to było już wcześniej), ale
  ma teraz **trzy kubełki zamiast dwóch**: `OK`, `NOT DONE` (odmowa lub awaria
  PRZED zniszczeniem — maszyna jest, jak była) i `CHANGED` — dataset, którego
  niszczenie ruszyło, a transfer się urwał. Pętla rollbacku produkuje ten stan
  wprost: cofa każdy dataset poddrzewa po kolei, więc odmowa na trzecim
  zostawia dwa pierwsze już cofnięte, a stary kod raportował je razem z
  nietkniętymi. `restore_one` niesie to rozróżnienie w kodzie wyjścia (2 od
  pierwszej mutacji, 1 dopóki jej nie było), a `CHANGED` **wygrywa** w kodzie
  wyjścia całego biegu.
  Dowód: `test/restore/relpolicy.sh` 15/15 plus `restoregrant` 108/108, i
  **trzy kontrole negatywne**, każda zabijająca dokładnie swoją część: drzewo
  bez pre-flightu wywala 6 przypadków D, drzewo zatrzymujące się na pierwszej
  awarii wywala 8 przypadków B, drzewo z dwoma kubełkami wywala 3 przypadki B3.
  **Pierwsza wersja tej polityki, z 2026-08-30, owinęła nie ten silnik.** Trafiła
  na `restore_replace_internal` — starszy silnik jednodatasetowy, który we
  własnym nagłówku ma „NO public door" — podczas gdy publiczny czasownik idzie
  przez `restore_run_scope`/`restore_one`. Testy przechodziły, kontrole
  dyskryminowały, i nic z tego nie było osiągalne z `restore`. Kontrola
  negatywna dowodzi, że przypadek mierzy funkcję, którą nazywa; nie umie
  zauważyć, że nikt tej funkcji nie woła. Zdublowane opakowanie usunięte, żeby
  nie było dwóch polityk.

- **POŁOWA B DOWIEDZIONA NA ŻYWYM ZFS — kampania i jej powtórka po sześciu
  poprawkach (2026-08-31).** Dźwignia: `zfs hold` na snapshocie uszkodzenia.
  Przechodzi pre-flight (blokady nie są tam sprawdzane) i wywala się dopiero na
  `zfs rollback -r` — czyli daje dataset, który **przechodzi kwalifikację i pada
  w wykonaniu**, dokładnie ten kształt, którego połowa B dotyczy. To nie jest
  sztuczka: blokada wbita w snapshot to stan, który ten projekt już raz mierzył
  przy pvesr.

  | wariant | wynik |
  |---|---|
  | awaria na **ostatnim** datasecie | `OK`, `OK`, `NOT DONE` → `PARTIAL -- 2 recovered, 1 untouched`, RC=1 |
  | awaria na **pierwszym** datasecie | `NOT DONE`, `OK`, `OK` → ten sam wynik, RC=1 |

  **Rozstrzyga drugi wariant.** Przy blokadzie na ostatnim datasecie dostaje się
  te same zielone liczby i **nie dowodzi niczego o kontynuacji** — po awarii nic
  już nie zostało do zrobienia. Dopiero awaria na **pierwszym** pokazuje, że bieg
  leci dalej. Miejsce, w którym umieszcza się awarię, jest tu całym testem.
  **Raport zgodny z dyskiem, sprawdzony przez `ls`, nie zaufaniem komunikatowi:**
  `znacznik.txt` NIE wrócił na dataset zgłoszony jako `NOT DONE` (cofnięcie było
  zablokowane), a `dane.bin` wrócił na obu zgłoszonych jako `OK`.
  **Powtórka potwierdziła też dwie poprawki w kierunku „ma nie krzyczeć":** oba
  odzyskane datasety dostały `OK`, a nie `CHANGED` jak w pierwszej kampanii
  (weryfikacja po tożsamości), a blok „co to kosztuje backup" **zamilkł**, bo
  snapshoty uszkodzenia nigdy nie trafiły na kopię.
  Po biegu: pliki na miejscu, blokady zdjęte, grant cofnięty, **zero pauz**,
  następny pull `All datasets processed successfully`.

- **PEŁNY LAB RESTORE PRZESZEDŁ BEZ ZACIĘCIA (2026-08-31, `main` @ bb5b6af).**
  Dziesięć kroków od czystego stanu, **żadnej poprawki kodu po drodze**, każde
  przewidywanie spisane przed uruchomieniem i trafione. To pierwszy przebieg
  tego dnia, który nie zaciął się ani razu — wcześniejsze zacięło się
  czternaście razy i z tego wzięło się czternaście wad.

  | krok | wynik |
  |---|---|
  | `--plan` | 25 punktów odzysku, nagłówek o spójności, **zero** utworzonych datasetów |
  | `--from-copy` w wolne miejsce | 3 datasety z dziećmi, GUID **3/3**, RC=0 |
  | z repliki w wolne miejsce | 3 datasety, GUID **3/3** zgodne z nośnikiem |
  | replika → **dataset kopii** (`--overwrite`) | `SAM ROLLBACK`, 24→12 snapshotów, pauza wzięta i zwolniona |
  | relacja, niszcząco | **3× `OK`**, pliki wróciły, snapshot uszkodzenia zniszczony |
  | `--at 16:10` | wybrał **15:57**, nie 16:57 — najnowszy *nie później niż* |
  | połowa B, awaria na **pierwszym** | `NOT DONE`, `OK`, `OK` → `PARTIAL 2/1`, RC=1 |
  | cross-host poza nadaniem | remap wypisany, `NOT DONE` nie `CHANGED`, „NOTHING landed", **zero** „stays paused" |
  | odmowy gramatyczne | **5/5** |
  | sprzątanie | granty cofnięte, zero blokad, zero pauz, `rpool/proba` nie istnieje, pull czysty |

  **Trzy rzeczy, które dzień wcześniej były zacięciami, przeszły same:** `--at`
  faktycznie cofnął bezczynne datasety, weryfikacja nie krzyknęła nad udanym
  odzyskiem, a nieudany `create` dostał `NOT DONE` zamiast wołania o człowieka.
  **Dwa bloki komunikatów sprawdzone w OBIE strony:** ostrzeżenie o koszcie
  backupu **odezwało się** przy `--at`, gdzie kopia naprawdę zostaje z historią,
  której źródło nie ma — i **zamilkło** wszędzie indziej. To jest ta połowa,
  którą przy naprawianiu fałszywego alarmu najłatwiej zepsuć.
  **Blokada w kroku B stała na PIERWSZYM datasecie, nie na ostatnim** — na
  ostatnim wynik byłby identyczny i nie dowodziłby niczego o kontynuacji.
  Stan po biegu: źródło dokładnie jak przed (`znacznik.txt`, `dane.bin`,
  `duzy.bin`, `nowe.bin`), kolektor tylko z `hdd/backups`, nośnik odłączony.

- **Krok per dataset jest IZOLOWANY procesowo (REV-20260831-127 F1,
  2026-08-31).** Kontroler relacji klasyfikuje kod wyjścia `restore_one` — a
  może to zrobić tylko wtedy, gdy `restore_one` **wraca**. `die` w tym drzewie
  to `exit 1`, a krok pojedynczego datasetu sięga do dużej ilości wspólnego
  kodu (odczyt configu, rozwiązanie relacji, strategia, snapshot techniczny),
  gdzie odmowa kończąca proces może dopisać się w każdej chwili. Jedno takie
  wyjście i polityka B po cichu przestaje być „idź dalej i oddaj, co się da",
  a staje się „stój tutaj" — bez podsumowania, z datasetami po nim nigdy
  nietkniętymi.
  Zmierzone na drzewie z 2026-08-31: `restore_one` i **wszystkie** jego funkcje
  pomocnicze są oparte na `return`, więc to nie był żywy incydent. To jest
  jednak fakt o dzisiejszym kodzie, nie gwarancja — dlatego granica jest
  **strukturalna**, nie opisowa. `restore_one_isolated` uruchamia krok w
  podpowłoce; cokolwiek z niej wychodzi (return, exit, `die` w głębi
  pomocniczej) wychodzi przez pułapkę EXIT, która przenosi na zewnątrz werdykt,
  flagę `RESTORE_ONE_CHANGED` i dopisy do `RESTORE_ROLLED_BACK`. Bez flagi
  `die` po pierwszej mutacji zostałby zdegradowany do „nietknięty", a to
  właśnie ten stan decyduje, czy operator dowie się, że maszyna wymaga
  człowieka.
  **Skutek uboczny, który jest własnością, nie kosztem:** stan nie przecieka
  między datasetami. Atrapa w `test/restoregrant` trzymała kursor w zmiennej
  rodzica i przestała się przesuwać — czyta teraz po nazwie datasetu.
  Dowód: `relpolicy` 24/24 (przypadki E1/E2 z atrapą, która **kończy proces**,
  a nie tylko zwraca — bo atrapa o innym kontrakcie sterowania niż funkcja,
  którą udaje, jest dokładnie tym, jak ta wada przeżyła zieloną suitę),
  `restoregrant` 108/108, i **czwarta kontrola negatywna**: drzewo bez granicy
  izolacji wywala 6 przypadków E.

- **Nieczytelny rekord relacji nie jest rekordem bez pola — LAB pve9,
  2026-08-31.** Restore uruchomiony z konta delegowanego odmawiał zdaniem
  „relationship record .../src8.conf **carries no CLIENT_NAME**". Pole było w
  pliku. Prawdziwa przyczyna: rekordy są `-rw------- root:root`, a konto nie
  mogło pliku otworzyć w ogóle. Odczyt szedł przez `sed 2>/dev/null`, który
  zwraca to samo nic w obu przypadkach, więc odmowa obwiniała treść za problem
  uprawnień. Operator idzie wtedy szukać pola, które tam stoi — na czasowniku,
  przy którym maszyna już leży. To ta sama różnica, którą ten plik od dawna robi
  o drugiej stronie łącza („nie mogłem sięgnąć" ≠ „nic tam nie ma"), tylko
  niezrobiona po własnej. Teraz `-r` sprawdzane przed odczytem, a komunikat
  podaje konto i prawa pliku.
  Przy okazji: odmowa przy dwóch configach skleja ścieżkę z następnym zdaniem
  (`...zfsbackup.confEach belongs...`) — brak separatora, poprawione.
  Dowód: `test/restore/records.sh` — 5/5 lokalnie plus kontrola, że czytelny
  rekord BEZ pola nadal dostaje swoją własną, inną odmowę. Przypadki
  nieczytelnego pliku **SKIP-ują na Windows** (Git Bash czyta 000) i mówią to
  wprost; wykonują się na runnerze CI.
  **Znalezione przez lab, nie przez suitę** — obie wady istniały, gdy cała
  bateria była zielona.

- **Jedna pisownia zakresu, i `--onto` na cel — GRAMATYKA MIĘDZYHOSTOWA
  ZAMKNIĘTA (decyzja właściciela 2026-08-30, `docs/project/OWNER-RESTORE-CROSS-HOST-GRAMMAR-2026-08-30.md`).**
  Decyzja z 26.08 zastąpiła `label:dataset` flagami `--source`/`--target`, ale
  dosięgła tylko przypadku jednej maszyny. Zmierzone na drzewie z 30.08: **obie
  pisownie żyły**, a przy podanym celu flagi były **odmawiane**, z odmową
  odsyłającą do dwukropka — czyli jedyna droga do „jeden dysk VM-a na inną
  maszynę" prowadziła przez pisownię, którą właściciel już zastąpił. Powód
  zastąpienia nie był teoretyczny: `:` jest legalny w nazwie datasetu ZFS i
  rozjechał już legalną lokalizację kopii `.../pool/data:archive` (#132).
  Teraz: nazwa relacji stoi sama, datasety idą flagami, a **`--onto` mówi, gdzie
  to ląduje** na maszynie docelowej — inna oś niż `--source`/`--target`, które
  mówią, w której przestrzeni nazw operator nazywa datasety. Pary są
  **pozycyjne**, listy muszą mieć równą długość, dwa datasety nie mogą wylądować
  na jednym, a dzieci zachowują pozycję względną. Dwukropek jest jeszcze
  czytany, ale **głośno ostrzega** i wskazuje nową pisownię.
  **`--onto` z jedną ścieżką i bez listy wyboru = cała relacja przesadzona
  tam.** Baza to najdłuższy wspólny przedrostek zapisanych korzeni, liczony **na
  granicach nazw** — `rpool/data/vm-101` i `rpool/data/vm-1010` dają
  `rpool/data`, nie `rpool/data/vm-101`. Pierwsza wersja tej reguły mówiła
  „korzeń jest odczytany, nigdy zgadywany"; napisałem ją, patrząc na gramatykę,
  a nie na config, i odmówiłaby dokładnie tej awarii, dla której ta forma
  istnieje — VM z czterema dyskami to **cztery** zapisane sekcje, czyli cztery
  korzenie. Ponieważ baza jest wywnioskowana, **jest drukowana** nad planem
  (`restore_report_rebase`): wnioskowanie, które operator potwierdza, nie jest
  zgadywaniem; jest nim takie, którego nikt nie widzi.
  Dowód: `test/restore/onto.sh` 14/14 i **trzy kontrole negatywne**, dwie
  punktowe: przedrostek liczony po znakach zabija dokładnie jedną asercję
  (granice nazw), pierwsze-dopasowanie zamiast najdłuższego zabija dokładnie
  jedną (dziecko nazwane wprost ma zachować swój cel), a przywrócenie zgubionego
  ostatniego pola listy zabija 7.
  **Znalezione przez własny test, nie przez przegląd diffu:** `printf '%s' | read`
  gubi ostatnie pole, bo bez końcowej nowej linii `read` zwraca niezero i ciało
  pętli nie wykonuje się dla niego. Jednoelementowa lista `--onto` rozwiązywała
  się do ZERA elementów, a odmowa skarżyła się wtedy na różne długości list —
  komunikat o objawie dwa kroki za przyczyną.

- **`--from-copy`: odzysk, gdy REKORDY RELACJI ZNIKNĘŁY — ostatni kawałek
  gramatyki z 13.08 ZAMKNIĘTY (2026-08-31).** Każdy inny adres tego czasownika
  idzie przez nazwę relacji, a nazwy relacji mieszkają w plikach na kolektorze.
  Strata tych plików = kopie, których nie da się nazwać, czyli zaprzeczenie
  sensu backupu, który ma przetrwać utratę tego, co go opisuje. Drugi przypadek:
  kopie po maszynie wycofanej z użycia — relacja skasowana celowo, dane nie.

      zfs-restore.sh --from-copy hdd/backups/pve1/hdd/labsrc --onto hdd/odzysk

  **Flaga, nie zgadywanie po kształcie**: `hdd` jest równie dobrą nazwą puli co
  relacji, a ten projekt raz już zapłacił za rozróżnianie po kształcie
  (dwukropek, #132). **`--onto` jest tu obowiązkowe** — przy relacji brak celu
  znaczy „z powrotem tam, skąd przyszło", bo rekord to wie; goła ścieżka nie ma
  rekordu, więc domyślny cel byłby wymyślony, nie odtworzony.
  **Ta forma NIGDY nie niszczy**, i to jest cały argument w jednym zdaniu:
  zniszczenie wymaga zgody, zgoda wymaga relacji, a goła ścieżka relacji nie ma
  — nie ma kto wydać zgody ani czego zapauzować. Jedynym pozostałym
  uzasadnieniem byłoby „operator stoi przy klawiaturze", czyli dokładnie ten
  argument, którym rozmontowuje się model zgody. Ląduje w wolne miejsce przez
  **ten sam silnik**, którego bezpieczne odtwarzanie używa od 15.08 (unikalny
  staging, weryfikacja GUID, przeniesienie przez `rename`) — nowy ADRES do
  dowiedzionego silnika, nie drugi silnik.
  Wszystko rozwiązuje się przed utworzeniem czegokolwiek: jedna zła para
  odrzuca całą listę i wymienia wszystkie złe.
  **Test złapał wadę, której przegląd diffu nie złapał:** domyślny punkt odzysku
  brałem przez `tail -1`, czyli **po kolejności listy** — dokładnie tę dziurę
  REV-121 zamknęła na innym domyślnym punkcie („`creation` jest osią, a remis
  odmawia"). Odtworzyłem ją w nowej ścieżce. Wyszło, bo atrapa zwraca wiersze
  **nieposortowane** — i dlatego je tak zwraca. Domyślny wybór idzie teraz przez
  ten sam wybierak co `--at`, z podniesionym sufitem.
  **Lab złapał drugą wadę, tym razem UKRYTE SPRZĘŻENIE (2026-08-31):** silnik
  lądowania tworzył rodzica **lądowania**, a nie przestrzeni **stagingu**
  (`<pula>/restore`). Przy adresie przez relację lądowanie leży *wewnątrz* tej
  przestrzeni, więc powstawała ona jako przodek — przypadkiem, i nikt nie
  zauważył, że nigdy o nią nie poproszono. Lądowanie gdziekolwiek indziej takiego
  szczęścia nie ma, a awaria wychodzi **po podglądzie i po potwierdzeniu**, przy
  odbiorze: `cannot open 'hdd/restore'`. Suity tego nie widziały, bo atrapują
  połowę lądującą — właściwa granica dla tego, co testują, i niewłaściwa dla
  sprzężenia między dwiema ścieżkami, które tylko wyglądały na jedną.
  **Trzecia wada, znaleziona przez laba GODZINĘ po wdrożeniu tej formy:**
  `--from-copy` wskazany na **rodzica** odtwarzał wyłącznie rodzica i drukował
  „Odtworzenie OK", podczas gdy dwa dyski pod nim po prostu nie powstawały.
  Sukces zgłoszony nad niekompletnym odzyskiem jest najgorszą rzeczą, jaką ten
  czasownik może zrobić — i jest to dokładnie ta wada, której forma przez
  relację nauczyła się unikać 27.08. Nowy adres napisałem **obok** tamtej lekcji,
  a nie na niej. Dzieci jadą teraz razem, **jeden wpis na dataset, nie jeden
  strumień rekurencyjny** — ten sam wybór i ten sam zmierzony powód: rekurencyjny
  send rozwiązuje rodzica i potrafi zostawić nietknięte dziecko stojące za
  punktem odzysku, a silnik wychodzi na tym zerem.
  Dowód: `test/restore/fromcopy.sh` 21/21 i **pięć kontroli negatywnych**: wybór
  po kolejności listy zabija 3 przypadki, usunięta kontrola zajętego celu zabija
  5 (w tym asercję nośną „silnik lądowania NIE zostaje uruchomiony"), a
  lądowanie dobrych par mimo złej zabija 10, usunięte tworzenie przestrzeni stagingu zabija 2, a nierozwijanie dzieci zabija 3.

- **Klasyfikator pytał o GŁOWĘ celu, a nie o punkt odzysku — LAB, 2026-08-31.**
  Zdalna klasyfikacja pytała: „czy najnowszy snapshot celu jest jednym z tych,
  które ma kopia?". Jeśli nie → `full-live` → tryb `replace`. To pytanie jest
  **fałszywe dla każdej maszyny, która pracowała dalej po ostatnim dobrym
  backupie** — czyli dla zwykłej awarii.
  Zmierzone: kopia i źródło miały **ten sam GUID** `12279236860074163308` pod
  dokładnie tym snapshotem, do którego bieg odtwarzał; na wierzchu leżał jeden
  snapshot uszkodzenia. Bieg zaklasyfikował `replace` i zażądał grantu
  niszczącego, podczas gdy cofnięcie o jeden snapshot trafiało w punkt **bez
  jednego bajtu na łączu**.
  Koszt nie jest kosmetyczny: `replace` niszczy dataset i wysyła go w całości —
  godziny i pełny rozmiar zamiast sekund — i wymaga tego jednego grantu, przy
  którym operatorowi każe się dwa razy pomyśleć. **Grant, którego zwykły
  przypadek nie może użyć, to grant, który operatorzy uczą się pomijać** — a
  tak niebezpieczny staje się domyślnym.
  Właściwe pytanie brzmi: czy cel **wciąż niesie GUID punktu odzysku**. Jeśli
  tak, cofnięcie go osiąga, cokolwiek narosło na wierzchu — a to, co narosło,
  jest już sprawą sondy `_ahead` gałąź niżej.
  `restore_remote_has_guid` odpowiada w **trzech stanach**, i trzeci jest całym
  powodem, dla którego to funkcja: 0 jest, 1 nie ma, 2 nie dało się zapytać.
  Zlanie 2 w 1 czyta nieosiągalny host jako „brak wspólnej bazy" i eskaluje do
  zniszczenia datasetu — ten sam kształt co F14 i co błąd `_arc`, oba w tym
  samym pliku.
  Dowód: `test/restore/hasguid.sh` 6/6 na kontrakcie sondy, plus dwie kontrole
  negatywne (zlanie „nie dało się zapytać" w „nie ma" zabija po jednej,
  dokładnie swojej). **Samej klasyfikacji żadna suita nie asertuje i to jest
  świadome** — decyduje o niej odpowiedź drugiej strony, więc asercja nad
  zaatrapowanym klasyfikatorem dowodzi atrapy. Ta połowa jest dowodzona na labie.
- **Ostrzeżenie „co to kosztuje backup" pytało ŹRÓDŁO, a twierdziło o KOPII —
  LAB, 2026-08-31.** Komunikat mówi: „kopia na tym kolektorze trzyma teraz
  snapshoty, których źródło już nie ma", i zapowiada odmowę następnego pulla.
  Predykat pod spodem pytał o co innego: co **źródło** miało za chwilę stracić.
  To się pokrywa tylko wtedy, gdy kopia stoi równo z głową źródła.
  Zmierzone: źródło niosło snapshot, którego kopia **nigdy nie dostała** (nie
  pasował do prefiksu pulla). Cofnięcie go nie kosztowało backupu nic — a bieg
  ogłosił zator, nazwał snapshot nieistniejący na żadnym kolektorze i
  zaproponował `zfs rollback -r` **na kopii** jako jedno z dwóch wyjść.
  Następny pull powiedział `All datasets processed successfully`.
  Fałszywy alarm nie jest tu niegroźny, bo **rada przy nim jest niszcząca**:
  operator, który uwierzy, cofnie własną historię backupu — a komunikat trzy
  linijki dalej ostrzega, że to samo cofnięcie kasuje **bookmarki**, czyli
  kotwicę, do której wraca replika na nośniku wymiennym.
  **To było już raz zmierzone i zapisane** — strażnik, który tu stał, niósł tę
  lekcję w komentarzu („a rollback that discards live writes destroys nothing
  the copy has… the very next pull said All datasets processed successfully")
  i mimo to pytał źródło. Wpisanie rozróżnienia w komentarz to nie to samo, co
  wpisanie go w predykat.
  Teraz czyta **własną listę kopii**, lokalnie i bez dodatkowego ssh, szukając
  snapshotów za punktem odzysku. Gdy kopia nie ma żadnego — blok milczy.

- **Odzysk Z REPLIKI DO KOPII — `--overwrite`, ten sam silnik (decyzja
  właściciela 2026-08-31).** Lądowanie w wolne miejsce nie jest odzyskiem dla
  10 TB: potrzebuje drugiego tyle miejsca i przenosi każdy bajt, podczas gdy
  **dataset kopii już stoi i dzieli historię z repliką**. Właściwa operacja to
  przyrost albo cofnięcie NA NIEGO.
  **Nie dopisano silnika.** `restore_replace_internal` zamieniał jedną nazwę na
  parę `(źródło, kopia)`, przeglądając relacje w configu — a **wszystko poniżej
  pracowało już na dwóch zwykłych ścieżkach**. Ten sam szew co przy
  `cmd_restore_safe`/`restore_safe_land` tego samego dnia: rozwiązywanie adresu
  na górze, maszyna na dole, dwa adresy do jednej maszyny. `restore_replace_pair`
  to ta maszyna, przejrzana w REV-119/120/121 i dowiedziona na prawdziwym ZFS.
  `--overwrite` jest **trybem** `--from-copy`, nie drugim czasownikiem: podział
  list, rozwijanie dzieci i rozwiązanie całości przed dotknięciem czegokolwiek
  to to samo pytanie, niezależnie od tego, czy cel jest wolny. Różni się reguła
  kolizji (cel MUSI istnieć) i wywołanie na końcu. Osobne słowo, nie końcówka
  przy `--onto`: **dwie flagi różniące się końcówką to jedna literówka od
  zniszczonych 10 TB**.
  **Grantu tu nie ma i nie jest potrzebny** — grant istnieje, bo push pisze po
  cudzej maszynie i tamta strona musi się zgodzić. Tu obie strony są lokalne.
  Bezpieczeństwo daje to, co silnik już robi: mierzy zbiór strat z technicznego
  snapshota i pyta, zanim cokolwiek zginie.
  **Właściciela ma jednak CEL.** Źródło relacji nie ma — replika leży w szufladzie
  — ale kopia kolektora tak, i pisze do niej pull. Więc: relacja celu jest
  **pauzowana** na czas biegu, a jej `atomic` nadal odmawia; podanie dwóch
  ścieżek nie może być obejściem tej odmowy. Cele z **dwóch różnych relacji**
  odmawiają — każda ma własny harmonogram do postawienia.
  **Żywy bieg złapał wadę w tym bloku minuty po jego wdrożeniu:** relacja
  rekurencyjna nazywa w configu swój KORZEŃ (`.../labsrc`), a odtwarzane są jej
  DZIECI. Porównanie na równość odpowiadało na węższe pytanie niż zadane, więc
  odzysk `.../labsrc/vm-900-disk-0` meldował „no installed relationship claims
  these destinations" i **nie brał pauzy**, podczas gdy pull pisał do tego
  datasetu przez cały czas. Teraz dopasowanie obejmuje sekcję i wszystko pod nią.
  Dowód: `test/restore/fromcopy.sh` 26/26 i kontrole, w tym ta nośna:
  **odwrócenie kolejności argumentów silnika** zabija dokładnie jedną asercję.
  Odwrotnie nie zawodzi — niszczy replikę i odtwarza ją z kopii, po cichu, a
  tego nikt nie cofnie.

- **Weryfikacja po odzysku pytała KSIĘGOWO, a odpowiadała o TOŻSAMOŚCI — LAB,
  2026-08-31.** Sprawdzenie „czy cel wylądował w punkcie" pytało `written@punkt`
  — ile bajtów zapisano od tego snapshotu — i każdą wartość niezerową czytało
  jako „nie w punkcie".
  To jest właściwe pytanie **przed** odzyskiem (`restore_remote_ahead` nadal je
  zadaje i łapie najczęstszą awarię: pliki skasowane z żywego systemu bez
  snapshotu). Jest niewłaściwe **po**, bo **odzysk sam zapisuje** — predykat
  mierzy wielkość, którą poprzedzający krok z definicji narusza.
  **Zmierzone podczas kampanii wycelowanej w coś innego:** dwa datasety
  wylądowały dokładnie w punkcie — najnowszy snapshot TO punkt, skasowane pliki
  wróciły — a bieg zgłosił `CHANGED AND UNFINISHED … they need a person`, kod
  wyjścia 2, bo `written@punkt` pokazało 8192. Najgłośniejszy alarm tego
  narzędzia podniesiony nad **udanym** odzyskiem; w prawdziwej awarii wysyła
  admina o trzeciej w nocy naprawiać to, co działa.
  **PRZYCZYNA USTALONA — POMIAR NA DWÓCH PULACH LABU, 2026-08-31.** Pisze
  **samo `zfs rollback`**. Cofnięcie przepisuje metadane datasetu do bloków
  urodzonych po txg snapshotu, a `written@` liczy dokładnie takie bloki — więc
  po **udanym** cofnięciu ta liczba nie może być zerem. Reszta jest **stała**:
  jeden blok metadanych, jeden zapis na kopię, zaokrąglony do sektora puli.

  | pula | sektor | `redundant_metadata=all` | `=none` |
  |---|---|---|---|
  | pve9 `hdd` (dyski 512 B) | 512 | **1024** | 512 |
  | pve1 `hdd` (`ashift=12`) | 4096 | **8192** | 4096 |

  Nie zależy od kształtu odzysku: jeden plik czy pięćset, 4 MB czy 64 MB,
  `rollback` czy `rollback -r`. Pojawia się nawet po cofnięciu, przed którym
  **nic się nie zmieniło**, a `referenced` wraca do wartości ze snapshotu co do
  bajta. Świeży `recv` zostawia 0 — dlatego potykała się o to wyłącznie ścieżka
  `rewind`. 8192 na pve1 to 4 KB sektora × dwie kopie metadanych.
  **Wcześniejszy zapis w tym dokumencie mówił, że „to nie samo cofnięcie
  (w izolacji 0)" — to było fałszywe obalenie i zostało tu zastąpione, nie
  dopisane.** Poprawka i tak od tego nie zależała: predykat odpowiadał na złe
  pytanie niezależnie od odpowiedzi.
  Teraz pyta o tożsamość: snapshot **jest** i jest **tym** (po GUID, nie po
  nazwie), a nad nim nic nie stoi. Oba to fakty, których udany odzysk nie może
  zaburzyć.
  Dowód: `test/restore/offpoint.sh` 6/6 i kontrola negatywna, która jest
  **realnym poprzednim kodem z `main`**, nie wymyśloną mutacją — wywala
  wszystkie sześć przypadków, w tym ten, że cel stojący w punkcie zgłasza jako
  niebędący w punkcie.

- **`--at` na bezczynnym datasecie NIE ROBIŁ NIC — LAB, 2026-08-31.** Sonda
  „czy cel różni się od punktu odzysku" — ta, której odpowiedź decyduje, czy w
  ogóle uruchomi się cofnięcie — pytała wyłącznie `written@punkt`, czyli o
  **bajty**. A dataset może mieć snapshoty nowsze od punktu przy **zerze
  zapisanych bajtów**: bezczynny dataset pod godzinowym harmonogramem jest
  dokładnie tym, czyli większość floty przez większość czasu.
  Zmierzone podczas biegu `--at` do punktu historycznego: `vm-900-disk-1` miał
  **dwa godzinowe snapshoty nad punktem** i `written@punkt = 0`. Sklasyfikował
  się jako `increment`, cofnięcie **nie uruchomiło się**, silnik nic nie wysłał,
  a jedyne, co to złapało, to weryfikacja końcowa poprawiona godzinę wcześniej.
  **Odzysk `--at` bezczynnego datasetu po cichu nie robił nic.**
  Nagłówek tej funkcji sam opisywał, że kiedyś zamieniono „jest nowszy" na
  „różni się", bo tamto pytanie gubiło pliki skasowane bez snapshotu. Ta zamiana
  była słuszna — i **zamieniła jedną ślepą plamę na drugą**, czego nikt nie
  zauważył.
  Teraz pytanie jest **sumą**: bajty zapisane od punktu **albo** jakikolwiek
  snapshot nowszy od niego. W tej kolejności — tania własność najpierw, listing
  dopiero gdy pokaże zero.
  Dowód: `test/restore/ahead.sh` 5/5, a kontrolą negatywną jest **realny
  poprzedni kod z `main`** — wywala dokładnie tę jedną asercję i nic poza nią.

- **Granica izolacji wynosiła też to, co odziedziczyła — LAB, 2026-08-31.**
  `restore_one` dopisuje do listy cofniętych snapshotów, granica wynosi tę
  tablicę z podpowłoki, a rodzic dokleja to, co dostał. Podpowłoka **dziedziczy
  kopię rodzica**, więc bez wyzerowania każdy dataset oddawał wszystko, co
  dołożyły poprzednie: trzy datasety dają sześć wpisów, nie trzy.
  Zmierzone w raporcie „co to kosztuje backup" po biegu `--at`: pierwszy dataset
  wypisany **trzykrotnie**, wzór `labsrc, labsrc, disk-0` — dokładnie sygnatura
  narastania. To raport, na podstawie którego operator działa, a snapshoty w nim
  są nazwane więcej niż raz.
  Moja wada z tego samego dnia, wprowadzona razem z izolacją procesową.
  Dowód: `relpolicy` 25/25 z nowym przypadkiem E3, kontrola negatywna to
  **realny kod z `main`** — wywala dokładnie E3.
  **Przy okazji test złapał moją drugą pomyłkę:** pierwsza wersja atrapy
  dopisywała w OBU przebiegach, więc pokazywała sześć wpisów także po poprawce.
  Prawdziwy `restore_one` wraca na granicy pre-flightu i nie ma czego zapisać.
  Atrapa, która nie odwzorowuje tego, mierzy samą siebie.
- **`--onto` odmawiał WSZYSTKIEGO na żywo — prefiks transportowy, LAB
  2026-08-31.** Korzenie przebudowy zachowywały `konto@host:`, a ścieżki, z
  którymi je porównywano, miały ten prefiks obcięty. Nic nigdy nie pasowało.
  Odmowa **drukowała ten sam napis po obu stronach własnego zdania** —
  „`…:hdd/labsrc` is not under any of the paths (`…:hdd/labsrc`)" — co jest
  najczytelniejszym możliwym objawem i i tak wymagało uruchomienia, żeby je
  zobaczyć.
  **Piętnaście przypadków jednostkowych i trzy kontrole tego nie złapały**, bo
  wszystkie używały **gołych ścieżek** — tego, po co sięga fixture, a nie tego,
  co niesie relacja. Dołożony przypadek z prefiksem; kontrolą jest realny kod z
  `main` i wywala dokładnie jego.
  Normalizacja siedzi teraz tam, gdzie odbywa się porównanie, a nie u
  wywołującego: dwie wielkości, które się zestawia, muszą być obcinane tą samą
  ręką.

- **Nieudany `create` raportowany jako „wymaga człowieka" — LAB, 2026-08-31.**
  Flaga „już dotknięte" jest ustawiana bezwarunkowo przed silnikiem i to jest
  właściwa wartość domyślna: od tej linii silnik **może** niszczyć. Przy trybie
  `create` nie może — celu nie było — więc werdykt „ZMIENIONE I NIEDOKOŃCZONE,
  wymagają człowieka" wysyła kogoś do maszyny, na której nic się nie stało.
  Zmierzone: `--onto` wycelowane poza nadanie maszyny docelowej padło na
  `create`, dostało `CHANGED`, a podsumowanie powiedziało **„(0 recovered,
  0 untouched)"** — twierdząc, że nic nie jest nietknięte, podczas gdy dataset
  oczywiście był. `rpool/proba` na tamtym hoście nie istniał ani przed, ani po;
  sprawdzone ręcznie.
  Degradacja **wyłącznie na dowód**: cel mówi, że datasetu nie ma. Częściowy
  odbiór, który coś zostawił, zachowuje głośny werdykt — i tak samo host, który
  nie odpowiedział. „Nie dało się zapytać" nigdzie w tym drzewie nie znaczy „jest
  dobrze".
  Dowód: `test/restore/createfail.sh` 3/3, kontrolą jest realny kod z `main` —
  wywala dokładnie asercję nośną, a przechodzi obie „nie wolno degradować", bo
  nigdy nie degraduje.
  **Test złapał po drodze moją trzecią dziś pomyłkę z podpowłoką:** atrapa
  sekwencjonowała odpowiedzi zmienną, a każdy wywołujący sięga przez `$( )`.
  Licznik mieszka teraz w pliku.

- **Raport o przekazaniu twierdził dwie nieprawdy — LAB, 2026-08-31.** Blok o
  biegu międzyhostowym drukuje się **także po awarii** i to jest celowe: częściowy
  odzysk zostawia ten sam rozjazd, a operator musi wiedzieć, która maszyna co
  trzyma. Ale otwierał się zdaniem **„the data is there"** niezależnie od wyniku.
  Zmierzone: bieg, który **nie odtworzył nic** (silnik odmówił `create` poza
  nadaniem), ogłaszał, że dane są na drugiej maszynie, i podawał komendę
  przekazania jej backupu. Pójście za tym kieruje harmonogram na maszynę, która
  nic nie trzyma.
  Druga fraza: **„'X' stays paused"** — a wywołujący zwalnia pauzę linijkę dalej,
  więc raport był obalany przez własne wyjście za każdym razem, gdy się
  wydrukował (`stays paused` stało bezpośrednio nad `resumed 'src8'`). Raport,
  który przeczy linii pod sobą, uczy operatora przewijać cały blok.
  Pierwsze zdanie idzie teraz za **faktem** — `RESTORE_LANDED`, do której biegacz
  dopisuje tylko zweryfikowane datasety — a nie za zamiarem. Drugie mówi, co
  naprawdę się stało z pauzą.
  **Przy okazji:** `${#TABLICA[@]}` na nieustawionej tablicy **wywala `set -u`**
  (sprawdzone), więc fixture'y sterujące tą funkcją muszą ją podawać. Produkcja
  jest bezpieczna, bo tablica jest deklarowana na poziomie pliku.

- **Dwa znaleziska recenzenta w kodzie z tego samego dnia (REV-128, REV-129,
  2026-08-31).** Oba `CHANGES-REQUIRED`, oba P1, oba w rzeczach, które sam
  dowodziłem kilka godzin wcześniej.
  **REV-128 — gramatyka zgadywana z długości list.** `--onto` ma dwa publiczne
  kształty o różnych kontraktach: z `--source`/`--target` to lista **pozycyjna
  równej długości**, bez wyboru — **jedna** ścieżka przesadza całą relację.
  Oba wywołania podawały korzenie w identycznym kształcie, więc funkcja nie
  mogła ich odróżnić i `--target a,b --onto x` wchodziło w gałąź „cała relacja":
  wyliczało wspólny korzeń i budowało cele, których operator nie podał jako par.
  Odtworzone co do znaku na wskazanym SHA: `rc=0 pairs=1 from=rpool/data
  to=hdd/recovered`. Przy niszczącym odzysku międzyhostowym **ciche zamienienie
  błędnej pary na inną poprawną to błąd celowania**, nie ułatwienie. Pochodzenie
  wyboru jest teraz jawnym parametrem, nie wnioskiem z liczby korzeni.
  **REV-129 — jeden GUID rodzica przyłożony do całego poddrzewa.** GUID należy
  do snapshotu **konkretnego** datasetu, więc przy weryfikacji rekurencyjnej
  poprawne dziecko zgłaszało się jako „ta sama nazwa, inny snapshot" — czyli
  **każdy udany odzysk rekurencyjny kończył się raportem, że wymaga człowieka**.
  Odtworzone: `rpool/data/child has a snapshot NAMED p but a DIFFERENT one --
  guid 222, expected 111`, na fixturze bez jednej wady. Teraz idzie **tabela
  tożsamości per dataset**, budowana po stronie kopii i kluczowana pozycją pod
  korzeniem; dataset spoza tabeli nie brał udziału w odzysku i nie jest sprawą
  tej kontroli.
  **Przy pisaniu tabeli test złapał wadę w niej samej:** `index($1,c)==1` łapie
  dataset, który tylko *zaczyna się* nazwą kopii (`hdd/copyINNY` pod `hdd/copy`).
  Ta sama pomyłka o granicę nazwy, którą naprawiałem tego dnia w korzeniu
  `--onto`. `zfs list -r` tego nie zwróci, ale tabela kluczowana pozycją nie ma
  się na tym opierać.
  Dowód: `onto` 19/19, `offpoint` 9/9. **Kontrole na całych plikach byłyby
  skażone** — zmieniły się sygnatury w harnessach, więc stary kod dostaje
  przesunięte argumenty i pada z innego powodu niż wada. Zamiast tego kontrole
  **punktowe na SHA-ach wskazanych przez recenzenta**, odtwarzające dokładnie
  jego pomiar.

- **Wersje silników** (bez zmian tą konsolidacją): `gen-cron.sh` v4.30,
  `snapsend.sh` v2.72, `snapget.sh` v2.69, `delsnaps.sh` v1.29,
  `check-snap-age.sh` v2.3.

- Bieżąca dostawa dla issue #9: **prosty przepływ dwuserwerowy** — `add-client --host` (domyślny backup), jeden prowadzony `deploy.sh --join` na źródle, jawny `seed` i jeden `activate` na kolektorze. Join odkrywa ZFS, pokazuje zakres, pozwala zaakceptować/edytować i nadaje grant; activate składa końcowy catch-up, opcjonalną zmianę adresu, weryfikację oraz podgląd i transakcyjną instalację crona. Retry wznawia z trwałego stanu; ukończona aktywacja jest no-op. Lokalne dowody: guided join 14/14, zfsbackup 430/430. **Dowód na dwóch żywych hostach/ZFS został wykonany i przyjęty 2026-08-24** — patrz sekcja „Tor czterech komend — ZAMROŻONY” niżej; ten tor nie jest już obowiązkiem otwartym.

- **Tor czterech komend — ZAMROŻONY (2026-08-24).**

  **Stan: zamknięty i zamrożony.** Recenzent wydał `STAGE ASSESSMENT — PASS`
  dla toru na dokładnej głowie `main@aded3734d5f73564cc886e53451ae0a52b55a684`,
  a PR #157 ma niezależne APPROVED dla dokładnego
  `f321ba5e41cfce85681d177e0ec7129be836128c`; CI `32762425113` — zielone, 38/38.

  Tor to cztery komendy publiczne, w tej kolejności:

  ```
  zfs-backup.sh add-client NAME --host=... --target=...      (kolektor)
  deploy.sh --join=...                                        (źródło)
  zfs-backup.sh seed NAME                                     (kolektor)
  zfs-backup.sh activate NAME [--host=...]                    (kolektor)
  ```

  **Co zostało dowiedzione na żywo** (kolektor pve9, źródło pve2, konto
  delegowane `bckp`; pełne transkrypty w issue #9):

  | próba | wynik |
  |---|---|
  | pełna ścieżka czterech komend na żywej relacji ZFS | **PASS** |
  | seed po LAN + transfer produkcyjny przez osobny endpoint WireGuard | **PASS** |
  | tożsamość GUID źródło/cel po przesłaniu ładunku ścieżką produkcyjną | **PASS** |
  | odczyt zwrotny pełnego CONFIG-u i crontaba konta właściciela | **PASS** |
  | powtórzenie całej sekwencji publicznej | **`0/0/0/0`**, bez zduplikowanych sekcji CONFIG-u i linii crona |
  | bramka tożsamości `add-client` | ten sam adres → no-op `0`; inny port, jawne konto lub inny target → odmowa `1` |

  **Co znaczy zamrożenie tego toru:** publiczna gramatyka i kolejność tych
  czterech komend, ich kontrakt wznawiania (ponowienie ukończonego kroku jest
  no-opem, rozbieżna tożsamość odmawia) oraz kształt dowodu są ustalone.
  Zmiana w tym torze wymaga **recenzji przed implementacją**, tak samo jak
  zmiana w pliku objętym `docs/project/ENGINE-FREEZE.md`. Dalsze poprawki
  dokumentacyjne i późniejsze findingi monitoringu są doradcze i **nie**
  otwierają tego etapu ponownie.

  **KROK 5 ZAMKNIĘTY (2026-08-25).** Zakres zapisany w wiążącym OWNER EXECUTION
  PLAN (issue #9, komentarz `5301880395`) — domknięcie wysokopoziomowego
  wdrożenia jednoserwerowego — został dostarczony i przyjęty niezależnie:

  | wymaganie planu | dowód |
  |---|---|
  | audyt „co już jest" wobec Gate 5, bez odbudowy planera, CONFIG-u, seeda, retencji ani transakcji crona | z sześciu wymagań pięć już istniało; dostarczono **jedno** brakujące (PR #159) |
  | root domyślnym wykonawcą | live, wariant root |
  | `--local-user` zmienia tylko konto, nie procedurę | live: blok w crontabie konta, crontab roota bajt w bajt bez zmian, granty ZFS nadane przez przebieg |
  | brak `--source` pokazuje propozycję i wymaga akceptacji | live: propozycja z inwentarza ZFS, `--yes` jej nie potwierdza |
  | target automatyczny tylko gdy jednoznaczny | live: zaproponowany `hdd/backups`; zgadnięty cel nie instaluje się nienadzorowany |
  | jedna ponowiona komenda wznawia | live: `EXIT=0`, md5 configu **i** crontaba identyczne, zero nowego seeda |
  | koniec = seed zweryfikowany, cron zainstalowany i odczytany z właściwego konta | live, oba warianty |
  | dowód na czystym hoście: root **oraz** konto delegowane, bez ręcznej edycji CONFIG-u, grantów i crontaba | oba PASS; host przywrócony do stanu sprzed testu |

  Znalezione i naprawione po drodze, bo dopiero żywy przebieg je pokazał:
  powtórzenie udanej komendy było FATAL-em zamiast no-opem; drugie źródło do
  tego samego celu było odrzucane przez własną sekcję `[prune:]` tego narzędzia;
  a scalanie linii crona przez `gen-cron` sprawiało, że dołożenie źródła
  przepisywało linię poprzedniego i bramka antykasacyjna słusznie odmawiała.

  Werdykty niezależne: `4eff863` APPROVED (#159), `6600024` APPROVED (#160 —
  advisory sondy pul). Scalone jako `main@bdbfc38` i `main@8604b76`.

  **Następny etap: ETAP PROFILI** — i tylko on. Kolejność: rozbicie `flags`
  według właściciela (krok 1) → pasmo do manifestu parowania (krok 2) → rodziny
  zarezerwowane edytowalne z profilu → `default` jako jawny parametr → kształt
  profilu. Podstawa: `docs/project/PROFILE-VARIABLE-INVENTORY.md` oraz dwie
  decyzje właściciela z 2026-08-25.

  Krok 1 **zrobiony** 2026-08-24 (oś łącza) i 2026-08-31 (oś zakresu) — patrz
  wpis „ETAP PROFILI, krok 1" na początku tego pliku, razem z listą tego, czego
  krok 1 świadomie nie robi.

- **KROK 5, plaster 1: brak `--source` proponuje zrodla (2026-08-25).**

  Wysokopoziomowa sciezka lokalna odmawiala bez `--source`, wiec „czysty host ->
  dzialajacy backup" zaczynal sie od recznego czytania `zfs list`. Teraz brak
  `--source` daje **propozycje z inwentarza ZFS tego hosta** i **wypisuje kazdy
  pominiety dataset wraz z powodem** (pula, cel backupu, `*/ROOT`, swap oraz
  dataset juz objety zainstalowana polityka).

  **Uklad hierarchiczny nie jest zgadywany.** Pierwsza wersja pomijala kazdy
  dataset majacy potomka i proponowala dzieci — a rodzic trzyma wlasne pliki
  niezaleznie od dzieci, wiec to zamieniało pozorne pokrycie na CICHY brak
  pokrycia (finding recenzji do plastra 1; wlasna suita kodowala te wade jako
  zachowanie oczekiwane, wiec byla zielona nad prawdziwa dziura). Zmierzone na
  zywym ZFS: pusty rodzic ma `usedbydataset=24576`, ten sam rodzic z 3 MiB
  wlasnych plikow — `3173376`; rozroznienie jest wiec mozliwe, ale tylko wobec
  progu wzietego z sufitu, ktorego ta funkcja nie ma prawa wymyslac. Dlatego
  decyduje UKLAD, nie rozmiar: gdy wsrod kandydatow jest para rodzic/dziecko,
  **to poddrzewo** wypada z propozycji — oba czlony, bo sam rodzic to pierwotna
  wada, a same dzieci to ta sama nieprawda w druga strone — z wypisana para,
  powodem i gotowymi do skopiowania liniami `--source=`. Reszta hosta jest
  proponowana normalnie: jedna hierarchia nic nie mowi o datasetach poza nia
  (zawezenie wg zalecenia recenzenta w trybie doradczym).

  Propozycja to zgadywanie, wiec niesie te sama regule co zgadniety cel:
  **`--yes` jej nie potwierdza**. Jawne `--source` nigdy nie jest podwazane
  (EXPLICIT-SOURCE-BEATS-DISCOVERY) — propozycja jest czytana wylacznie wtedy,
  gdy operator nie nazwal niczego.

  Zmierzone na zywo (pve9, worktree, host przywrocony do stanu sprzed testu):
  propozycja `hdd/k5src` + `hdd/osrc` z pominietym `hdd`; odmowa pod `--yes`
  nazywajaca zrodla przy niezmienionym hashu crontaba; **wariant root** — EXIT=0,
  seed z weryfikacja GUID, diff crontaba to dokladnie jeden dodany blok
  zarzadzany; **wariant konta delegowanego `bckp`** — EXIT=0, blok w crontabie
  konta, crontab roota bajt w bajt bez zmian, granty ZFS nadane na zrodle i celu.

  **Dwa blockery tej samej sciezki — zmierzone na `main@aded373` (kontrola na
  nietknietym buildzie), NAPRAWIONE tutaj po przejsciu recenzenta w tryb
  doradczy:** powtorzenie tego samego udanego polecenia konczylo sie FATAL-em
  o nakladaniu zamiast byc no-opem; a dodanie **drugiego** zrodla do tego samego
  celu bylo odrzucane, bo wlasna sekcja `[prune:<cel>]` z pierwszego
  uruchomienia liczyla sie jako cudza nakladka.

  Jedna przyczyna: kazda sekcja pisana przez `local-backup` otwiera sie markerem
  `# managed-by: zfs-backup.sh local-backup <rodzaj>=<wartosc>`, **i nikt go nie
  odczytywal**. Teraz zadane zrodlo trafia do jednego z trzech kubelkow — NASZE
  (marker nasz i `dst` rowny zadanemu celowi; nic do zrobienia), NOWE (brak
  sekcji; to jedyne, ktore sie komponuje) albo SPORNE (sekcja cudza albo nasza,
  ale wskazujaca inny cel; fail-closed, ta sama odmowa co zawsze). Gdy nie ma
  zadnego nowego zrodla, przebieg jest **no-opem**: bez seeda, bez zapisu crona,
  config bajt w bajt ten sam. Retencja celu i rodzina szablonow zrodlowych sa
  emitowane **raz na cel**, nie raz na przebieg.

  **Trzecia rzecz, ujawniona dopiero przez zywy przebieg:** `gen-cron` SCALA
  datasety o tej samej polityce w jedna linie crona, wiec dolozenie drugiego
  zrodla nie dodawalo linii — przepisywalo linie pierwszego zrodla na
  dwudatasetowa. Bramka antykasacyjna, zgodnie z wlasnym kontraktem („linia
  ktora znikla to zadanie ktore przestalo chodzic"), odmawiala instalacji,
  wymieniajac jako ofiary wlasne linie pierwszego zrodla. Dwie zmiany, obie
  waskie:

  * **wlasna minuta na kazde zrodlo lokalne** (ten sam rozrzut, ktorego uzywa
    sciezka zdalna) — linie przestaja sie scalac, wiec tozsamosc istniejacej
    linii nie zmienia sie, gdy dochodzi kolejne zrodlo; przy okazji dwa zrodla
    nie kopiuja do tego samego magazynu w tej samej minucie;
  * **drugie zwolnienie w bramce**, o tym samym ksztalcie co istniejace
    zwolnienie dla zmiany endpointu: zgubiona linia jest wchlonieta wylacznie
    wtedy, gdy w nowym bloku jest linia IDENTYCZNA poza jednym cytowanym
    argumentem, w ktorym stara lista datasetow jest PODZBIOREM nowej. Kierunek
    jest cala wlasnoscia bezpieczenstwa i jest pinowany w obie strony: lista
    ktora sie ZWEZA nadal jest kasacja. Piec dyskryminatorow: scalenie
    wchloniete, linia po prostu nieobecna — nie; zwezenie — nie; zmieniony prog
    — nie; zmieniony harmonogram — nie.

  **Dwie dalsze uwagi recenzenta, obie trafne i obie poprawione:**

  * „juz objety" bylo testowane **nakladaniem sciezek**, a zadanie lokalne jest
    PLASKIE — `[dataset:rpool/a]` nie kopiuje `rpool/a/child`. Nowe dziecko pod
    zainstalowanym rodzicem bylo wiec pomijane jako „juz objete" i **nigdy nie
    proponowane**: to samo ciche zniknięcie pokrycia co w F1, tylko od drugiej
    strony. Teraz „juz objety" to **dokladna tozsamosc datasetu**, chyba ze
    zainstalowana sekcja jawnie deklaruje `recursive` — wtedy naprawde obejmuje
    poddrzewo. Trzy dyskryminatory: nowe dziecko pod plaskim rodzicem, rodzic
    przy zainstalowanym dziecku, oraz kontrola, ze sekcja rekurencyjna nadal
    obejmuje potomkow;
  * zwolnienie w bramce **poszerzalo dowolny** cytowany argument, co dowodzi
    zawierania zbioru, ale nie tego, ze ten zbior jest POKRYCIEM — szerszy cel,
    prefiks albo etykieta mogly udawac zachowane pokrycie datasetow. Teraz
    rozpoznawana jest komenda i **pozycja argumentu datasetow w jej wlasnym
    segmencie** (od nazwy skryptu do przekierowania stderr), bo liczenie od
    konca calej linii bralo pod uwage cudzyslowy opakowania — pierwsza wersja
    robila dokladnie odwrotnie, niz powinna. Nieznana komenda nie dostaje
    zwolnienia w ogole. Dwanascie dyskryminatorow, w tym cztery kontrole „tylko
    cel / prefiks / wzorzec / lista `-P` sie poszerza — nie wolno wchlonac".

  **F3: ta sama regula musi obowiazywac na OBU koncach.** Nauczenie jej samej
  propozycji dalo falszywa zielen — odkrywanie oferowalo dziecko pod
  zainstalowanym plaskim rodzicem, a bramka kompozycji odrzucala kandydata,
  ktorego przed chwila sama zaproponowala. `config_section_overlap` czyta wiec
  teraz to samo: **dokladna tozsamosc zawsze koliduje**; zadanie LEZACE POD
  zainstalowana sekcja koliduje tylko wtedy, gdy ta sekcja jest rekurencyjna;
  a sekcja lezaca POD zadana sciezka koliduje tylko wtedy, gdy to, co ten
  przebieg napisze, bedzie ja obejmowac rekurencyjnie — czyli w przypadku CELU,
  ktorego retencja jest emitowana `recursive = yes`. Sciezki rekurencyjne
  nazywa **wywolujacy**, bo tylko on wie, co zaraz wyemituje.

  Testy end-to-end sprawdzaja caly przebieg, nie brak frazy: kod wyjscia,
  zainstalowany CONFIG, przetrwanie starego zadania, obecnosc nowego oraz
  pokrycie obu w zainstalowanym cronie — dla obu ukladow (zainstalowany plaski
  rodzic + nowe dziecko; zainstalowane dziecko + kandydat-rodzic) plus odmowa,
  gdy zainstalowana sekcja naprawde jest rekurencyjna.

  Dowod live (pve9, worktree, host przywrocony do stanu sprzed testu): pierwsza
  instalacja `EXIT=0`; **powtorka tego samego polecenia `EXIT=0`, md5 configu
  i crontaba identyczne, snapshot nadal jeden** (zero seeda); **drugie zrodlo
  `EXIT=0`**, w crontabie dwie osobne linie wysylki na minutach 10 i 30, monitor
  zrodel scalony do `"hdd/k5a,hdd/k5b"` (pokrycie zachowane), retencja celu
  jedna.

  Dyskryminatory pinuja obie polowy: no-op nic nie sieje i nic nie zapisuje;
  drugie zrodlo dolacza, a pierwsze przezywa; cudza sekcja pod ta sama sciezka
  **nadal odmawia**; nasza sekcja wskazujaca inny cel **nadal odmawia** (to inne
  zadanie, nie powtorzenie).

- **Sonda pul: awaria przestala byc cisza (2026-08-25, `check-pool-capacity.sh` v6).**

  Advisory recenzenta do PR #131, dwukrotnie ponawiane. Generowany skrypt
  zdrowia mial dwie sciezki fail-open: `for pool in $(zpool list -H -o name)`
  wykonuje cialo petli **zero razy**, gdy enumeracja padnie, a
  `health=$(zpool list -H -o health ...)` z testem `[ -n "$health" ]` milczy,
  gdy odczyt jednej puli sie nie powiedzie. W obu wypadkach „nie udalo mi sie
  sprawdzic" docieralo do operatora jako „sprawdzilem i jest dobrze" — czyli
  dokladnie ta klasa wady, dla ktorej ten plik powstal (rpool na pve1 stal
  DEGRADED tygodniami, bo zdrowia nie sprawdzal nikt; sonda, ktora nie umie
  krzyknac, tez go nie sprawdza).

  Teraz enumeracja jest **jedna** i jej wynik ma trzy rozne odpowiedzi:
  `rc != 0` -> finding „sonda pul PADLA" i **zadna** z petli sie nie wykonuje;
  `rc == 0` z pusta lista -> osobny finding „ZERO pul" (na hoscie z tym
  pakietem to nie cisza, tylko brak zaimportowanej pamieci); w przeciwnym razie
  praca idzie dalej. Nieodczytany `health` i nieodczytana `capacity` sa
  findingami per pula — ta druga wczesniej dawala blad powloki na stderr i
  **zaden** alert.

  `CAPACITY_SCRIPT_MARKER` podbity `v4` -> `v6`, bo deploy podmienia ten skrypt
  tylko wtedy, gdy marker sie nie zgadza: bez podbicia poprawka nie dotarlaby na
  zadnego hosta z flotą, ktora juz ma v4 (ta sama pulapka co REV-088 —
  sprawdzenie po nazwie serwuje stara tresc w nieskonczonosc).

  **Druga runda (v6): sonda, ktora sie powiodla, to inne pytanie niz wyjscie,
  ktore wyglada dobrze.** Finding recenzenta: `health=$(zpool list ...)` uznawal
  `ONLINE` za sukces takze wtedy, gdy komenda wypisala `ONLINE` i **padla**,
  a `cap=$(zpool list ... | tr -d '%')` gubil kod `zpool` na rzecz kodu `tr`.
  Teraz rc jest przechwytywany z samej sondy i sprawdzany **przed** trescia,
  a `%` obcina rozwiniecie parametru zamiast potoku. Pusta odpowiedz przy
  `rc=0` i padnieta sonda to dwa **rozne** komunikaty — operator wie, ktora
  cisza go spotkala.

  `test/alertmail`: **34/0**, +7 asercji. Kontrola negatywna wobec builda sprzed
  poprawki: **szesc padа**, a siodma — „gdy wszystkie sondy odpowiadaja, zdrowy
  host nadal milczy" — przechodzi po obu stronach, wiec suita mierzy dokladnie
  te zmiane, a nie „skrypt zaczal alarmowac zawsze".

- **ETAP PROFILI, krok 2: pasmo przeniesione do MANIFESTU PAROWANIA (2026-08-25).**

  Decyzja wlasciciela. Limit opisuje **drut**, a drut nalezy do **pary hostow**
  — nie do relacji. Na rekordzie relacji dwie relacje do tego samego peera przez
  to samo lacze trzeba bylo ograniczyc **dwa razy, recznie**, i nic nie
  pilnowalo, zeby sie nie rozjechaly. Teraz mieszka w
  `PEER_SAVED_BANDWIDTH` w manifescie parowania, gdzie jedna odpowiedz obsluguje
  kazda relacje lecaca po tym laczu.

  `deploy.sh --pair --bandwidth=RATE` zapisuje wartosc (walidacja przepisana
  z silnika: `^[0-9]+[bkKmMgG]?$`, BAJTY na sekunde). `add-client --bandwidth=`
  **przekazuje** ja do parowania zamiast trzymac wlasna kopie.

  **Zmiana limitu pary nie jest efektem ubocznym zapisywania nowej relacji.**
  Druga relacja proszaca o inny limit nie pyta o siebie — prosi o przecechowanie
  wszystkiego, co juz po tym laczu lata. Dlatego jest to **odmowa** nazywajaca
  obie wartosci, a nie ciche zastosowanie w ktoraktolwiek strone. Trzy kontrole
  pilnuja, ze to nie zamienilo sie w „odrzucaj `--bandwidth` zawsze": pominiety
  limit przyjmuje limit pary, ten sam limit nie jest konfliktem, a peer bez
  parowania przyjmuje limit bez sporu.

  **Zgodnosc:** rekord napisany przed przeniesieniem jest nadal honorowany, gdy
  manifest milczy — **zadna wdrozona relacja nie zmienia predkosci przez ten
  commit** — a operator dostaje raz komunikat z gotowa komenda, gdzie ta wartosc
  teraz nalezy. `add-client` **przestal** pisac druga kopie do rekordu: to ta
  kopia poszlaby w rozsyp i to ja operator by edytowal.

  Obie zrodla sa **czyszczone przed** zrodlowaniem plikow, bo jeden proces
  laduje wiele rekordow (monitory, audyty), a wartosc po poprzednim ograniczylaby
  relacje, ktora o nic nie prosila — w kierunku, ktorego nikt nie zauwazy, bo
  transfer wolniejszy niz powinien nadal sie udaje.

  `test/linkfields`: **49/0**. Kontrola negatywna wobec `main`: **szesc
  asercji o pasmie pada**, a trzy kontrole „nie wolno odmowic" przechodza po obu
  stronach. Po rebase na `main` (etap profili krok 2 wszedl pierwszy) sekcja
  10 z `main` — behawioralny test przeciekania limitu miedzy rekordami —
  podnosi teraz rowniez `resolve_link_bandwidth`, bo funkcja pod testem
  wola ja, odkad limit mieszka w manifescie. Kontrola mutacyjna: usuniecie
  `BANDWIDTH=""` daje 47/2 — pada test behawioralny I grep zrodla, wiec
  slabszy nie niesie ciezaru mocniejszego.

- **ETAP PROFILI, krok 1: `flags` rozbite wzdluz osi LACZA (2026-08-25).**

  `bandwidth`, `compression` i `cipher` opisuja **drut**, po ktorym leci
  dataset — nie polityke, ktorej podlega, i nie tozsamosc, ktora sie laczy.
  Nie mialy wlasnych pol: jedynym sposobem, zeby powiedziec cokolwiek z tej
  trojki, bylo wpisanie litery silnika do wolnego `flags` — tego samego
  stringa, ktory niesie klucz parowania, przypiety klucz hosta i port, i ktory
  z tego powodu jest w `PROFILE_FORBIDDEN_FIELDS`. **Zadna warstwa powyzej
  recznej edycji nie mogla wiec powiedziec „ogranicz tego peera do 2 MB/s".**
  To byla mechaniczna, nie projektowa przeszkoda dla calego etapu profili.

  Kazde pole renderuje **dokladnie** ten token, ktory operator wpisalby recznie
  — dowiedzione przez wyrenderowanie obu zapisow i porownanie wywolania
  silnika. Ta sama opcja przychodzaca **i** z `flags`, **i** z pola jest
  **odrzucana**, nie scalana: dwa zrodla prawdy dla jednej opcji to dokladnie
  ten stan, ktory ten podzial ma zakonczyc. Kontrola dubla uzywa tego samego
  przejscia po opcjach co getopts, wiec zbundlowane `-eb 2M` jest lapane,
  a argument `-m b-daily_` nie jest.

  **Tylko `[dataset:]`, i profil ich nie ustawia**: nosnik polityki jest
  wspoldzielony przez datasety, ktore **nie dziela celu** — ta sama retencja
  obsluguje gigabitowy LAN i VPN 20 Mbit. Profil nie wie, po jakim laczu
  poleci.

  Pulapka kolejnosci przypieta kontrola: jawny kompresor sprawia, ze autotune
  silnika **staje**, wiec pola musza sie renderowac PRZED rozwazeniem `-A`.
  Odwrotnie daje linie crona z `-A` i `-Z` naraz, czyli zadanie ogłaszajace
  no-op przy kazdym uruchomieniu.

  **F3 recenzji: limit przeciekal miedzy rekordami.** `load_client_and_connection`
  zerowal przed zrodlowaniem tylko `CLIENT_TARGET`. Rekord bez pola `BANDWIDTH`
  nie nadpisuje zmiennej, wiec w komendach ladujacych wiele rekordow w jednej
  powloce (`migrate-profile`, `audit-source-retention`) klient ograniczony,
  a po nim nieograniczony, zostawial temu drugiemu limit pierwszego: `-b 2M`
  w wywolaniu silnika i linie `bandwidth` w jego sekcji. Relacja, ktora o zaden
  limit nie prosila, cicho zwalnia — w kierunku, ktorego nikt nie zauwazy, bo
  transfer wolniejszy niz powinien nadal sie udaje. `BANDWIDTH=""` dolaczylo do
  resetu, a dyskryminator wykonuje **prawdziwa funkcje dwa razy w jednej
  powloce**, bo ta sekwencja JEST calym findingiem — test wolajacy ja raz nie
  moglby go zobaczyc.

  `test/linkfields`: **36/0**, z kontrola negatywna wobec poprzedniego
  `gen-cron.sh` wbudowana w kazdy przebieg — musi odrzucic wszystkie trzy pola
  jako nieznane.

- **ETAP PROFILI, krok 3: `default` WYKRYSTALIZOWANY — rodziny zarezerwowane sa
  trescia profilu, nie kodu (2026-08-25).**

  Cel wlasciciela na faze 1: „profil `default`, ktory dokladnie odwzoruje obecne
  ustawienie lab", podany do skryptu jawnie, z dowodem, ze lab idzie identycznie.

  Ostatnia rzecza, ktorej w profilu nie bylo, byla lista rodzin zarezerwowanych —
  literalne `"__replicate_" "vzdump" "__migration__"` z `keep=2` w
  `ensure_cron_config`. Czyli **jedyna polityka, pod ktora chodzi KAZDA relacja
  na tej flocie, byla jedyna, ktorej profil nie umial opisac**: „co robi domyslne
  wdrozenie" odpowiadalo sie grepem po kodzie. Teraz sa w
  `profiles/<nazwa>/templates.conf`, a kod nie zna zadnej rodziny z nazwy.

  **Dowod fazy 1 na zywym hoscie** (pve9, worktree, host przywrocony do stanu
  sprzed testu):

  | przebieg | config | crontab |
  |---|---|---|
  | bez `--profile` | `02898f51` | `c3d2e41e` |
  | `--profile=default` | `02898f51` | `c3d2e41e` |
  | `diff` | **rc=0** | **rc=0** |

  Oba `EXIT=0`, realny seed, cron odczytany zwrotnie, trzy sekcje `[excluded:]`
  z `keep = 2` — podlogi przyszly z profilu, a nie zniknely.

  **Konsekwencja projektowa, ktora wyszla dopiero z implementacji:** dwa rodzaje
  sekcji **skladaja sie inaczej**. `[template:]` jest namespace'owany, wiec
  renderowane pliki wolno **sklejac** — to wlasnie po to namespace istnieje.
  `[excluded:]` jest wspoldzielony i celowo NIE zmienia nazwy, bo dwa profile
  mowiace `__replicate_` mowia o tej samej rodzinie; sklejenie dawalo wiec
  zduplikowana sekcje i `gen-cron` slusznie odmawial. Render rozdzielony na dwa
  artefakty: szablony zostaja bezpieczne do konkatenacji, wspoldzielone ida
  osobno do instalatora podlog, ktory dokłada tylko to, czego w configu nie ma.
  **Regula ogolna: sekcje namespace'owane skladaja sie przez konkatenacje,
  wspoldzielone przez ZGODNOSC.**

  `default` przestal tez byc szescioma literalami w kodzie — jest jedna nazwana
  stala `PROFILE_DEFAULT_NAME`. Dlatego „jawny default zachowuje sie jak brak
  flagi" da sie w ogole asercjonowac, a nie tylko zalozyc.

  **Jeszcze nie zrobione, nazwane wprost:** odmowa, gdy dwa profile deklaruja te
  sama rodzine z ROZNYM `keep`. Dedup dziala, odmowa nie — a faza 2 czyni to
  pilnym, bo beda dwa profile na jednym hoscie.

- **KATALOG PROFILI: WIELKOSC LITER = KSZTALT, KOHERENCJA POZA GODZINOWA
  (2026-08-27).** Regula wlasciciela, w jego slowach: *"male litery w nazwie,
  czyli nie GFS (...) d30h24 powinny tworzyc 30 szt. daily i 24 szt hourly. Te
  daily powinny byc coherentne. Gdyby byl D30H24, to bylby GFS."*

  **Co bylo:** `d30h24`, `d7h24` i `d30` tworzyly JEDNA rodzine (`d30`:
  `automated_daily_`, pozostale: `automated_hourly_`) i przycinaly ja drabina
  GFS. „Dzienny" snapshot na takim hoscie **nie istnial jako osobny byt** — to
  byl snapshot godzinowy, ktory licznik postanowil zatrzymac. Dlatego nie dalo
  sie go zamrozic osobno: zamrozenie dziennego = zamrozenie wszystkich
  dwudziestu czterech.

  **Co jest:** trzy profile przebudowane na ksztalt `prod` — kazdy tier tworzy
  wlasna rodzine i przycina wlasna rodzine, bez sekcji `[prune]` i bez `gfs`.
  Zmierzone na renderze przez PRAWDZIWY `gen-cron.sh`:

  | profil | tworzy | przycina | koherentne |
  |---|---|---|---|
  | `d30h24` | `automated_hourly_`, `automated_daily_` | `-H24`, `-D30` (dwie linie) | daily |
  | `d7h24`  | `automated_hourly_`, `automated_daily_` | `-H24`, `-D7` | daily |
  | `d30`    | `automated_daily_` | `-D30` | daily |
  | `default`| bez zmian — `automated_hourly_` | drabina `-G -H24 -D7 -W4 -M12` | zadne (drabina nie moze) |

  **Godzinowy nie jest zamrazany nigdzie** i to jest teraz asercja obejmujaca
  CALY katalog, sprawdzana na wyrenderowanej linii crona (nie na polu `quiesce`
  w profilu — pole musi jeszcze przejsc namespacing, scalanie szablonow
  i asembler flag, zanim stanie sie `-q`, a to `-q` uruchamia host).

  **Wielkosc liter jako kontrakt:** mala = rodzina na tier, wielka = drabina GFS.
  Zadnego profilu z wielkiej litery jeszcze nie ma; rozroznienie istnieje, zeby
  dalo sie je odczytac z `ls`. Obie polowy reguly maja asercje — wielka litera
  bez `-G` odmawia, mala z `-G` odmawia.

  **Znalezisko uboczne, zmierzone przez skasowanie pliku:** na systemie plikow
  bez rozroznienia wielkosci liter (ta stacja, kazdy checkout na macOS)
  `D30H24.conf` i `d30h24.conf` to **JEDEN plik** — zapis jednego nadpisuje
  drugi, a skasowanie kasuje oba. Hosty linuksowe rozroznilyby je, wiec awaria
  ujawnilaby sie wylacznie na stacji roboczej, jako profil, ktory po cichu
  zmienil ksztalt. Suita odmawia katalogu zawierajacego obie wersje jednej nazwy.

  **Nic w produkcji z tego nie wynika:** cztery zywe hosty jada na recznie
  pisanych configach z `cron-configs/`, zaden nie odwoluje sie do tych profili.
  Zmiana dotyczy relacji zakladanych OD TERAZ.

  **Sprawdzone przy okazji, bo kontrakt `profile-config-schema` na to wskazuje:**
  monitory `check-snap-age.sh` sa emitowane wewnatrz galezi prune, wiec dataset,
  ktory przestaje przycinac, po cichu przestaje byc monitorowany. Po
  przebudowie kazda rodzina ma swoj monitor z wlasnymi progami (`90m/150m`
  godzinowy, `30h/48h` dzienny) — zweryfikowane na renderze. Asercja `zfsbackup`
  o „dokladnie jednej drabinie `-G`" dotyczy profilu `default` i pozostaje
  nietknieta. `zfs-backup.sh` juz umie profil bez fragmentu `[prune]`
  (`profile_declares_ladder`, dodane gdy `prod` po raz pierwszy trafil na pve9),
  wiec trzy przebudowane profile ida ta sama, sprawdzona sciezka.

  **Dowody:** `test/profiles` **78/0** (nazwa = retencja liczona z UNII linii
  `delsnaps`, nie z pierwszej; ksztalt vs wielkosc liter w czterech
  kombinacjach; koherencja calego katalogu z dwiema kontrolami mutacyjnymi —
  zamrozony godzinowy i niezamrozony dzienny oba padaja; kontrola pozytywna na
  `prod`, ze petla w ogole czytala linie). `localbackup`: CI.
  Katalog opisany w `profiles/README.md`.

- **ODTWARZANIE NA INNA MASZYNE I `move-to-client` — DOWIEDZIONE NA TRZECH
  HOSTACH (2026-08-28).** pve9 (kolektor) trzyma kopie relacji `lab1` z pve1.
  Sparowano pve2 jako `lab2`, odtworzono na nia cala relacje, przekazano jej
  kopie, i wrocono.

  **Scenariusz wlasciciela, zrealizowany w calosci:** relacja, ktorej maszyna
  jest wymieniana, **nie jest klonowana — przenosi sie**. Kopia zostaje na
  kolektorze; zmienia sie to, z ktorej maszyny jest backupowana.

      zfs-backup.sh restore lab1 lab2      # odzysk na nowa maszyne
      zfs-backup.sh move-to-client lab1 lab2   # przekazanie kopii

  **Dowod, o ktory chodzilo:** po przeniesieniu kopia miala **22 snapshoty** —
  najstarszy z ery pve1, najnowszy z pierwszego backupu z pve2 — **jedna ciagla
  linia przez podmiane maszyny**, 10,1 MB, zero ponownego seedu. To jest cala
  teza tej decyzji: "bez sensu by bylo kopiowanie w te i we wte".

  **Cztery wady, wszystkie z labu:**

  | # | wada |
  |---|---|
  | F23 | `replace` na **korzeniu nadanego zakresu** niszczyl sama delegacje — `zfs allow` siedzi NA datasecie, a odtworzenie go wymaga praw na rodzicu, ktorych konto delegowane nie ma. Zostawilo cel bez datasetu, bez zgody i bez mozliwosci zrobienia jednego i drugiego |
  | F24 | ...i nie musialo: **pusty dataset przyjmuje pelny strumien przez `recv -F`**. `replace` siegal po `-f` w obu podprzypadkach, a to dwie rozne roboty. Rozdzielenie ich sprawia, ze zwykla awaria (swieza maszyna, pusty dataset) jest w ogole odzyskiwalna |
  | F25 | **prune ZRODLA zostawal na starej maszynie** — enumerowalem sekcje z rekordu relacji, a jego listy nie niosa zakresu `konto@host:sciezka`. Po przekazaniu kasowalby snapshoty na maszynie, ktorej relacja juz nie obejmuje |
  | F26 | **rekordy nie jechaly z sekcjami** — cel nie zapisywal, co teraz posiada, wiec drugie przeniesienie odmawialo "nie ma czego przekazac" dla relacji, ktora miala wszystko |

  **Dowod po GUID zadzialal na stanie, ktorego nie ustawialem:** przy powrocie
  kopia byla juz do przodu (backup z pve2), pve1 nie mial najnowszego snapshotu
  — `move-to-client` odmowil i podal komende naprawcza. Dokladnie po to jest.

  **OBA KIERUNKI TRYBU, ZMIERZONE:**

  | cel | tryb | dowod |
  |---|---|---|
  | pve2 — pusty dataset, swieza maszyna | `replace` (full-bare) + `create` dla dzieci | pelny strumien przez `recv -F`, bez niszczenia datasetu |
  | pve1 — MA dane i wspolna baze | **`rewind`** | **przyrost na istniejaca linie**: 27 snapshotow, najstarszy `2026-08-27_14-51-01` sprzed calej kampanii, 10,6 MB |

  Ten drugi wiersz jest pomiarem, nie deklaracja: gdyby to byl pelny wysyl z
  `-f`, dataset zostalby zniszczony i odtworzony, a snapshoty z 27 sierpnia by
  nie istnialy.


  **Gramatyka miedzyhostowa otwarta:** `restore A B` (te same sciezki) i
  `restore A:ds B:ds2`. Cel to **etykieta relacji, nigdy nazwa hosta** — czyli
  maszyna, z ktora kolektor jest juz sparowany, ma przypiety klucz i moze
  poprosic o zgode. Zero nowej klasy adresu. Cel musi byc tylko **sparowany**,
  nie aktywowany.

  **Odzysk i przekazanie zostaja osobne** (decyzja wlasciciela): to dwie rozne
  dziedziny awarii, a dowod po GUID jest naturalnym szwem — czasownik, ktory sam
  ten warunek wytwarza i sprawdza, sprawdza wlasna robote. Zamiast zlozenia:
  `restore` konczy zdaniem, ze dane sa na maszynie, do ktorej nic nie pokazuje,
  i podaje nastepny krok.

  **Znaleziona przy okazji wada NIE z tej rundy:** `deploy.sh --commit-scope=`
  **nigdy nie dzialalo** — wola `do_commit_scope` w linii 3044, a funkcja jest
  zdefiniowana w 5552. Na `main` tak samo. Sciezka `--join` wola ja pozniej,
  wiec tam dziala. Nie naprawione, bo to osobna sprawa.

  **Lab sprzatniety:** pve2 bez danych, bez konta, bez zgod, relacja rozebrana
  (`--leave`); pve9 z `lab1` czynna i `lab2` wycofana; wszystkie trzy hosty na
  `main`; cron bez sladu po pve2.


- **ODTWARZANIE: DRUGI PRZEBIEG LABU. PIERWSZY MOWIL "DZIALA OD KONCA DO
  KONCA" I BYLO TO PRAWDA WYLACZNIE DLA KSZTALTOW, KTORE PRZESZEDL (2026-08-27).**

  Pierwszy przebieg (pve9 kolektor -> pve1, dwa dyski jednej VM, konto
  delegowane, prawdziwy transfer) znalazl osiem wad i zamknal sie zdaniem
  "dowiedzione od konca do konca". Drugi przebieg tego samego dnia, na tym samym
  labie, znalazl **czternascie kolejnych** — bo zaczal od rzeczy, ktorej pierwszy
  nie zrobil ani razu: **uruchomil backup po odtworzeniu**, i uszkodzil dane w
  sposob, w jaki uszkadza je awaria, czyli **bez snapshotu po szkodzie**.

  **Najgorsza z nich, i powod, dla ktorego ten wpis brzmi tak a nie inaczej:**
  przy zwyklej szkodzie (skasowane pliki, zaden snapshot od tego czasu)
  odtworzenie melduje `all 3 dataset(s) in scope recovered` i **nie zmienia
  niczego**. Klasyfikator pytal, czy cel ma snapshot NOWSZY od punktu; nic nie
  bylo nowsze, wiec nie bylo rollbacku, silnik dostal przyrost o dlugosci zero i
  wyszedl z zerem. Pierwszy przebieg tego nie zobaczyl, bo tam kazda szkoda byla
  po drodze zesnapshotowana przez backup.

  **Wady drugiego przebiegu (F9-F22):**

  | # | wada |
  |---|---|
  | F9  | po odtworzeniu **nastepny backup relacji odmawia**, a odmowa obwinia pisarza, ktorego nie ma; samo odtworzenie o tym nie mowilo |
  | F10 | odmowa podawala lekarstwo (`-f`), ktorego konto relacji **nie moze uruchomic**; `-F` przy tym milczalo o przyczynie |
  | F11 | `restore` **nie znajdowal configu na zadnym hoscie floty** (`jobs.<host>.conf` zamiast `jobs.<host>.<konto>.conf`), a trzy `FATAL` po kolei **nie zatrzymywaly programu** — `die` w `$( )` konczy podpowloke |
  | F12 | `--target` nie potrafil nazwac **zadnego dysku VM** — tylko rodzica |
  | F13 | odtworzony system plikow wracal **niezamontowany** i nikt tego nie mowil |
  | F14 | "jest i pusty" czytane jako "host nie odpowiedzial" |
  | F15 | odmowa podpowiadala `deploy.sh --allow-restore=` **z pusta etykieta** — dokladnie wejscie z E1 w dzienniku bledow |
  | F16 | `replace` byl nadawany, klasyfikowany i **pokonywany przez montowanie**, z podpowiedzia prowadzaca donikad |
  | F17 | **meldunek sukcesu nie byl pomiarem** (wyzej) |
  | F18 | rollback rodzica **zerowal przyrost**, wiec dziecko z tylu nie dostawalo nic |
  | F19 | rodzic oceniany po dzieciach, ktore sa juz osobnymi pozycjami — werdykt zalezal od kolejnosci petli |
  | F20 | sonda rozrozniala dwa przypadki, a **wywolujacy je z powrotem sklejal** (dwa razy, w tym samym pliku) |
  | F21 | skasowanie snapshotow to **polowa** lekarstwa — zywy system plikow kopii zostaje z przodu |
  | F22 | run **oglaszal zator, ktorego nie bylo**, w srodku odtwarzania |

  **Warianty przebiegniete i potwierdzone tresciowo** (kazdy sprawdzony przez
  zawartosc plikow ORAZ `written@<punkt>`, nie przez kod wyjscia):

  | wariant | wynik |
  |---|---|
  | `--plan`, cala relacja | tylko odczyt, nic nie ruszone |
  | `--at` + cala relacja, cel do przodu | rollback trzech datasetow, tresc z punktu |
  | `--at` + `--target` jeden dysk | tylko ten dysk; drugi nietkniety |
  | `--target` lista po przecinku | oba, jeden do przodu i jeden do tylu w jednym biegu |
  | cala relacja bez `--at` | najnowszy punkt, trzy datasety |
  | **`create`** — dataset celu zniknal | odtworzony, wlasciwosci wrocily |
  | **`replace`** — cel istnieje, brak wspolnej bazy | odmowa bez zgody -> zgoda -> wykonane |
  | **brak zgody** | trzy odmowy, cel nietkniety |
  | zator: kontrola dodatnia i ujemna | ostrzega dokladnie wtedy, gdy zator jest |

  **Petla domknieta bez zacięcia:** szkoda -> odtworzenie -> ostrzezenie
  wymieniajace snapshoty -> **wypisana komenda uruchomiona doslownie** -> backup
  przechodzi -> dane zgodne. To jest kryterium, ktorego pierwszy przebieg nie
  postawil.

  **Zmiany w zamrozonym silniku (`snapget.sh`), wylacznie diagnostyka:**
  odmowa rozroznia teraz "kopia jest z przodu" od "ktos tu pisal", nazywa
  snapshoty i podaje `zfs rollback -r`, a podpowiedz o `recv -F` jest bramkowana
  faktyczna przyczyna zamiast `-f`. Zaden przebieg nie zmienia werdyktu, statusu
  ani skutku. Wpisy w `ENGINE-FREEZE.md`, baseline przepiety.

  **PAUZA OBEJMUJE TERAZ PRUNE, A ODTWORZENIE JEJ WYMAGA (2026-08-27).**
  Decyzja wlasciciela: "kazdy restore musi zostac poprzedzony pauza. Grant i
  pausa." Oraz: "pausa ma wstrzymac wszelkie operacje cronowe naszego pakietu z
  prunem wlacznie."

  `delsnaps.sh` dostal `-L` i czyta znacznik pauzy — **zmiana zachowania w
  zamrozonym silniku**, pierwsza na tym pliku, na wyrazne polecenie wlasciciela
  (wpis w `ENGINE-FREEZE.md`). gen-cron emituje `-L` na wszystkich czterech
  ksztaltach linii prune: inline, `[prune:]`, GFS `[prune:]` i
  `[prune-bookmarks:]` (ta ostatnia sekcja dostala `pair_label` do gramatyki —
  bookmark jest tym, na co restore spada, gdy snapshotu juz nie ma).

  **Nie przez wylaczenie crona:** crontab hosta niesie zadania, ktore nie sa
  nasze. Przelacznik zostaje per relacja, w naszych wlasnych zadaniach.

  `restore` **odmawia**, gdy nie da sie zalozyc pauzy, i podaje komende. Pauzy
  zalozonej przez czlowieka nie zdejmuje. Zasieg pauzy jest **mierzony, nie
  zakladany**: run liczy linie prune w zainstalowanym crontabie bez `-L` i je
  zglasza, bo crontab wygenerowany przed ta zmiana przycina mimo pauzy.
  Zmierzone na labie: najpierw "2 z 2 bez -L", po regeneracji "wszystkie 2
  niosa -L".

  **KOLEJNOSC WDROZENIA (zatwierdzona 2026-08-28): NAJPIERW KOD, POTEM
  CRONTABY.** Stary `delsnaps` dostajac `-L` traktuje je jako pierwszy argument
  pozycyjny i **pada z rc=1** (zmierzone) — nic nie kasuje, ale caly prune tej
  relacji staje i alarmuje az do aktualizacji kodu. Awaria glosna i bezpieczna,
  ale awaria.

  Kroki, w tej kolejnosci:

  1. gałąź trafia na `main` (recenzent);
  2. hosty **same** pobieraja kod — godzinny `git pull --ff-only origin main`
     jest mechanizmem wdrozenia w tym projekcie; nic sie nie kopiuje recznie;
  3. potwierdzic na hoscie, ze `delsnaps.sh -h` wymienia `-L`, **zanim**
     ktokolwiek dotknie crontaba;
  4. dopiero wtedy regeneracja: `gen-cron.sh -c <zainstalowany config>
     --install` **uruchomiona jako konto relacji** (nie root — REPO_DIR
     wyprowadza sie z miejsca, gdzie lezy skrypt);
  5. przed instalacja zrobic kopie: `crontab -l -u <konto> > kopia`, po niej
     zdiffowac. Jedna linia poza zarzadzanym blokiem — godzinny self-update
     `git pull` — **ma przetrwac**; jesli znika, cofnac z kopii.

  **ILE TO REALNIE DOTYCZY — PRZEGLAD FLOTY (tylko odczyt, 2026-08-28):**

  | host | konto | linie prune | z `-L` | `pair_label` w configu |
  |---|---|---|---|---|
  | 192.168.28.8 pve2 | zfsbackup | 4 | 0 | **0** |
  | 192.168.28.9 pve1 (metropolis) | zfsbackup | 4 | 0 | **0** |
  | 192.168.28.99 pve9 | zfsbackup | 2 | 0 | 3 |
  | 192.168.11.10 pve0 | zfsbackup | 12 | 0 | **0** |
  | 192.168.11.11 pve1 | root + zfsbackup | 3 + 1 | 0 | **0** |

  **Wniosek, ktory zmienia rozmiar tej roboty: regeneracja crontabow na
  produkcji nie zmieni ANI JEDNEJ linii.** gen-cron emituje `-L` wylacznie tam,
  gdzie sekcja niesie `pair_label`, a produkcja pracuje na starych configach v4,
  ktore nie deklaruja relacji. Jedynym hostem, na ktorym cokolwiek sie zmieni,
  jest **pve9** (kolektor labu). Pułapka kolejnosci z punktu wyzej jest
  prawdziwa co do zasady i **nie ma dzis celu na flocie**.

  **WIEKSZE ZNALEZISKO PRZY OKAZJI, DO DECYZJI WLASCICIELA: pauza logiczna jest
  na produkcji BEZWLADNA.** Zmierzone: 26 linii wysylkowych na trzech hostach
  (pve2 4, pve1 8, pve0 14) i **zero** z nich niesie `-L`. Do tego pve2 i pve1
  maja **0 rekordow klientow** (sa strona obslugiwana, nie kolektorem).
  `pause-client` na tych hostach albo nie ma czego zapauzowac, albo zapisze
  znacznik, ktorego zadne zadanie nie czyta.

  To nie jest regresja z tej rundy — tak bylo od poczatku modelu relacji;
  produkcja po prostu nigdy na niego nie przeszla. Znaczy jednak dwie rzeczy:
  odtwarzanie relacji produkcyjnej dzis i tak nie zadziala (config nie deklaruje
  etykiety, wiec `restore <etykieta>` nie ma czego rozwiazac), a wymog pauzy,
  ktory wlasnie stal sie twardy, jest na tych hostach nie do spelnienia.
  Migracja produkcji na configi z `pair_label` to osobny etap.


  **pada z rc=1** (zmierzone) — nic nie kasuje, ale caly prune tej relacji
  staje i alarmuje az do aktualizacji kodu. Awaria glosna i bezpieczna, ale
  awaria. Regenerowac crontaby dopiero po tym, jak `-L` jest na hostach.


  **HARMONOGRAM NA CZAS ODTWARZANIA (pytanie wlasciciela, 2026-08-27).** Cron
  kolektora biegl przez cala kampanie i **skasowal punkt odtworzenia**: prune
  zrodla o :21 zastosowal drabine GFS do zrodla swiezo cofnietego przez restore
  i usunal `automated_hourly_2026-08-27_18-15-00`. Relacja zostala bez wspolnego
  snapshotu.

  `restore` bierze teraz **pauze logiczna** relacji na czas biegu i oddaja ja
  wylacznie wtedy, gdy sam ja zalozyl; pauze czlowieka zostawia. **Nie** pauze
  twarda: `disable-client` blokuje u peera te same komendy data-plane, ktorymi
  restore pod push dociera do maszyny — twarde wylaczenie zablokowaloby samo
  odtworzenie.

  **Czego ta pauza NIE obejmuje, i run to mowi:** `delsnaps.sh` nie ma `-L`, nie
  czyta znacznika, a gen-cron nie emituje `-L` w liniach prune (zmierzone: dwa
  zadania prune, zero z `-L`). Pauza zatrzymuje pull i monitor, nie zatrzymuje
  retencji. Sam `pause-client` juz to zglasza; restore powtarza to tam, gdzie
  czyta operator odtwarzania. W produkcji drabina GFS ogranicza szkode (24
  godzinne), wiec odtworzenie w oknie godzin jest bezpieczne; ryzyko rosnie przy
  dlugim odtwarzaniu i przy punktach starszych niz najgestszy szczebel.


  **Czego lab NIE dowiodl:** odtwarzania na inna maszyne lub inna sciezke
  (wariant miedzyhostowy), relacji push (kopia zdalna — rozszerzanie zakresu do
  poddrzewa i pomiar montowania sa dzis warunkowane lokalna kopia), oraz
  odtwarzania kontenera/VM ktora faktycznie sie potem uruchamia.


- **RESTORE: PRZEBIEG PO CALEJ RELACJI — IDZIE DALEJ PO PORAZCE (2026-08-27).**
  Decyzja wlasciciela 7. Implementer rekomendowal zatrzymanie na pierwszej
  porazce; wlasciciel to odrzucil, bo **odtwarzanie to nie wdrozenie**:
  zatrzymanie zostawia maszyne w polowie odtworzona I bez informacji o reszcie,
  dokladnie wtedy, gdy pelny obraz jest najbardziej potrzebny.

  Co to obliguje, i to jest asercjonowane: raport jest **werdyktem per dataset**,
  nie liczbą — „7/10" nie mowi operatorowi o 3 w nocy niczego, czym moglby
  dzialac, a trzy nazwy tak; a **dziewiec z dziesieciu nie konczy sie zerem**.

  **Dwa kody, nie trzy.** `0` = kazdy dataset w zakresie odtworzony, `1` =
  nie kazdy. Planer uzywa dokladnie tego kontraktu przy niepelnym `--at`, a
  trzeci kod dzielacy „czesc" od „nic" bylby kontraktem, o ktory wlasciciel nie
  prosil — ta roznica jest w RAPORCIE, gdzie moze nazywac datasety zamiast je
  liczyc.

  **Pusty zakres to odmowa, nie czysty przebieg.** „Nic nie pasowalo" konczace
  sie zerem to sposob, w jaki literowka w zakresie staje sie odtworzeniem, w
  ktore ktos uwierzyl.

  **Brak kroku per-dataset jest STRUKTURALNY, nie opisany w komentarzu.**
  `restore_one` to nastepny kawalek; `restore_run_scope` sprawdza `declare -F`
  i odmawia, zamiast wolac nieistniejaca funkcje — bo taka awaria przychodzi w
  chwili pierwszego uzycia, a dla czasownika odtwarzajacego to najgorsza z
  mozliwych chwil. Bramka znika sama w dniu, w ktorym krok powstanie; para
  asercji z kontrola pilnuje, ze dotyczy `restore_one`, a nie „odmawiaj zawsze".

  **Kontrola mutacyjna:** `break` na pierwszej porazce (zlamanie decyzji 7) psuje
  **trzy** asercje, w tym te nosna — dataset PO porazce nadal jest probowany i
  jest w raporcie.

  `test/restoregrant` **94/0** (+15). Nadal **nic tu nie potrafi zapisac**.


- **RESTORE: CO SILNIK DOSTANIE DO WYKONANIA (2026-08-27).**
  Transport odtwarzania to `snapsend.sh` — silnik push puszczony w drugą stronę
  (decyzja wlasciciela). Przychodzi z bookmarkami, wznawianiem, kompresja,
  limitem pasma i ochrona snapshotow Proxmoxa; **zamrozony plik nietkniety**.

  **Galka juz istniala** i warto zapisac, jak blisko bylo niepotrzebnej zmiany
  w zamrozonym silniku. `-e` jest udokumentowane jako „use existing LATEST
  snapshot", co czyta sie jak „silnik wybiera sam". Implementacja **najpierw
  filtruje kandydatow przez `-m`** i dopiero z tego bierze najnowszego — wiec
  PELNA nazwa snapshotu podana jako `-m` zostawia dokladnie jednego. Zmierzone
  przed oparciem sie na tym. Pytanie wlasciciela („napewno jej nie
  przewidzielismy?") jest tym, co zatrzymalo zmiane.

  **I dlatego regula dopasowania jest czescia kontraktu.** Silnik wybiera przez
  `grep "^$MESSAGE"` — REGEX zakotwiczony tylko z przodu. Kazda nazwa, ktora ten
  projekt generuje, jest obojetna dla regexa, ale tryb pasywny adoptuje nazwy
  z cudzych systemow, a `.` dopasowuje dowolny znak. Zmierzone: wobec
  `snap.2026` / `snapX2026` / `snap.2026b` wzorzec `^snap.2026` trafia
  **wszystkie trzy**.

  `restore_point_unique` dowodzi wiec jednoznacznosci **regula silnika**, nie
  jej przyblizeniem — implementacja uzywajaca `grep -F` albo `=` przepuscilaby
  pierwszy przypadek i wyslala INNY snapshot niz wybrany, co wyglada dokladnie
  jak sukces. To jest para dyskryminujaca w suicie.

  `restore_engine_argv` wyprowadza flagi **z klasyfikacji**, a nie obok niej
  (decyzja wlasciciela 4): `create`/`rewind` bez `-f`, `replace` z `-f` (to on
  niszczy cel), a `-e` i `-m <dokladna nazwa>` na kazdej formie — odtwarzanie
  nigdy nie tworzy snapshotu na kopii i nigdy nie pozwala silnikowi wybrac
  punktu. Kontrola: `-f` pojawia sie wylacznie dla `replace`.

  `test/restoregrant` **79/0** (+16). Ten kawalek **dalej nie potrafi nic
  zapisac** — buduje komende i odmawia; wykonawcy nie ma.


- **RESTORE: ZGODA (grant) — PIERWSZY KAWALEK, 2026-08-27.**

  Decyzja wlasciciela o kierunku: **kolektor zaczyna** (*"Zacznij od push"*,
  *"Kto zaczyna: kolektor"*). Sekcja 1 dokumentu
  `OWNER-RESTORE-GRANT-AND-MODES-2026-08-26.md` mowila odwrotnie i zostala
  poprawiona — powstala wczesniej tego samego dnia.

  **Dlaczego to czyni zgode calym bezpieczenstwem, a nie dodatkiem:** przy
  wariancie „maszyna prosi sama" nadpisywana maszyna bylaby ta, ktora prosi,
  i zadne uprawnienie do pisania po cudzej maszynie nigdy nie musialoby
  istniec. Przy push musi. Zgoda jest jedyna rzecza, ktora stoi miedzy
  „kolektor odtworzy mnie, gdy poprosze" a „kolektor moze mnie nadpisac, kiedy
  zechce".

  **Znalezisko, ktore uksztaltowalo ten kawalek — projekt wskazywal zle
  miejsce.** Dokument klad zgode w `relationships/<label>/` i w tym samym
  akapicie pisal, ze katalog jest „root-owned, the account has read-only
  access". **Nie jest.** `deploy.sh` robi go `root:<konto>` **0775**, celowo:
  model wlasciciela z 2026-08-06 pozwala kluczowi relacji zdjac twarda pauze,
  a zdjecie jej to unlink znacznika W TYM katalogu. Zgoda trzymana tam moglaby
  wiec zostac **zalozona przez konto kolektora** — czyli to, przed czym ma
  chronic. Zgody leza teraz we wlasnym drzewie `restore-grants/`, `root:root`,
  konto tylko czyta. Asercja strukturalna pilnuje, ze nie wroci pod tamten
  katalog, z kontrola negatywna sprawdzajaca, ze tamten NAPRAWDE jest
  grupowo-zapisywalny (inaczej asercja bronilaby wymyslonego zagrozenia).

  **Trzy czasowniki na maszynie zagrozonej**, lokalnie, jako root:
  `deploy.sh --allow-restore=LABEL [--replace]`, `--deny-restore=LABEL`,
  `--show-restore=LABEL`. `--show-restore` **nie wymaga roota** — pytanie „czy
  cokolwiek moze mnie nadpisac" musi byc do zadania przez kazdego, kto stoi
  przy maszynie.

  **`replace` nigdy nie jest domyslne** (*"REPLACE jawnie przy nadawaniu"*).
  Zwykla zgoda pozwala pisac tam, gdzie pusto. Kasowanie tego, co juz jest,
  trzeba napisac wprost, wczesniej, gdy nic nie jest zepsute. Ponowne wydanie
  zgody **nie poszerza** zywej zgody po cichu: rozne tryby = odmowa nazywajaca
  obie wartosci i droge (`--deny-restore` najpierw); te same tryby = no-op
  sukces, jak `disable` w bramce.

  **Zgoda nie wygasa i nie jest jednorazowa** (*"usun expires i nonce"*) — bo
  odtwarzanie moze trwac godzine albo weekend. Cena jest nazwana: zapomniana
  zgoda zyje dalej, wiec bramka `zfs-pair-gate` raportuje ja w
  `PAIR-CONTROL status`, w obu stanach relacji. Bramka **tylko czyta** —
  asercja strukturalna zabrania jakiegokolwiek zapisu do drzewa zgod, plus trzy
  proby wymuszenia zgody czasownikiem przez klucz kolektora.

  **Defekt znaleziony przez wlasna suite:** `--allow-restore=` z PUSTA wartoscia
  przelatywalo przez `[ -n "$LABEL" ]` i deploy.sh szedl dalej do Fazy 1 —
  czasownik odpowiadajacy na pytanie o UPRAWNIENIA zaczynal instalowac pakiety
  na hoscie. Dokladnie klasa F4 z 2026-08-26. Naprawione dyskryminatorem
  `*_GIVEN`, tak jak `--bandwidth` juz to robi.

  **`test/restoregrant` 44/0** (+1 SKIP: `chmod 000` nie odbiera prawa
  wlascicielowi na tym systemie plikow — asercja zglasza to zamiast udawac).
  Wykonawca odtwarzania NIE zostal ruszony; ten kawalek nie potrafi niczego
  nadpisac.
- **REV-20260827-122: DWA BLOKERY P1 Z RECENZJI NAPRAWIONE (2026-08-27).**
  Recenzent nie komentowal PR-a — otworzyl i zmergowal `#167` z formalnym
  werdyktem CHANGES REQUIRED na `b0a3a28`. Odpowiedz:
  `docs/internal/reviews/responses/REV-20260827-122.md`.

  **F1 — migracja profilu podanego SCIEZKA nie wymieniala jego szablonow.**
  Petla usuwania interpolowala `$target_profile` surowo, wiec dla
  `--profile=/tmp/mine.conf` szukala `[template:profile__/tmp/mine.conf__...]`,
  a renderer zapisal `[template:profile__mine__...]`. Nic nie pasowalo, nic nie
  zostalo usuniete, `ensure_cron_config` jest ADDYTYWNE — wiec stare szablony
  stlumily dopisanie edytowanej polityki, kandydat zainstalowal sie czysto ze
  STARA retencja, a rekord dostal NOWY digest. Nastepny przebieg czyta ten
  digest i idzie sciezka „nothing to migrate". Cicha rozbieznosc miedzy tym, co
  twierdza rekordy, a tym, co egzekwuje crontab — w RETENCJI.

  **Bylo w TRZECH miejscach, nie w jednym.** Recenzent nazwal jedno; grep za
  regula znalazl dwa kolejne: `schedule_tier_exprs` i `schedule_template_expr`
  budowaly `profile__${PROFILE_ACTIVE}__...` surowo, a `PROFILE_ACTIVE` **bywa
  sciezka** (ustawia je `--profile=`, a rekord klienta niesie ten sam napis).
  Koszt pustej odpowiedzi stamtad jest zapisany w komentarzu tuz nad tym kodem:
  **brak rozrzutu harmonogramow** — wszystkie relacje na tej samej minucie, co
  lab dwuzrodlowy zlapal w pierwszej minucie (#148/#149). Dowod, ze to byla wada
  a nie interpretacja: renderer w tym samym pliku JUZ uzywal
  `profile_name_of "$PROFILE_ACTIVE"`. Regula istniala; trzy miejsca jej nie
  stosowaly.

  **F2 — lista zakresu konczaca sie przecinkiem byla po cichu skracana.**
  Komentarz nad straznikiem mowil wprost, ze `a,b,` ma byc odrzucone. Petla
  szla `while [ -n "$rest" ]`, wiec dla `a,` rozwiazywala `a`, oproznila ogon
  i wychodzila ZANIM zdazyla zbudowac pusty ostatni element, dla ktorego ten
  straznik istnial. Nazwanie dziury nie jest jej zamknieciem.

  **Kontrole negatywne na `b0a3a28`, obie dyskryminujace:**

  | | naprawione | `b0a3a28` |
  |---|---|---|
  | F1: 122e „migracja sie udaje" | PASS | **PASS** |
  | F1: 122f wyrenderowana retencja `-D30`→`-D10` | PASS | **FAIL** |
  | F1: 122j i zostaje po trzecim przebiegu | PASS | **FAIL** |
  | F2: `"a,"` | odmowa | **ACCEPTED (1 member)** |
  | F2: `",a"` / `"a,,b"` / `"a,b,,"` | odmowa | odmowa |

  122e przechodzace po obu stronach jest sednem: komenda melduje sukces, a
  retencja nigdy sie nie rusza. F2 pokazuje, dlaczego istniejacy test podwojnego
  przecinka byl zielony — tylko przypadek terminalny byl otwarty.

  **Asercja F1 liczy sie na WYRENDEROWANEJ linii crona**, nie na fragmencie
  configu ani na rekordzie, bo oba byly juz „poprawne", podczas gdy crontab
  egzekwowal co innego. Ta luka JEST wada.

  **Dwie wady higieny testow, obie moje, obie o krok od pojscia jako dowod:**
  tryb celowany `--section` byl nieuzywalny (funkcje fikstur wewnatrz bloku
  pomijanego przy takim przebiegu — egzekucja L0 z REV-109 po cichu zepsuta);
  oraz siedem z dziesieciu moich nowych asercji uzywalo `check`, ktorego ta
  suita nie definiuje — przebieg meldowal `PASS=138 FAIL=0`, a asercja niosaca
  cale znalezisko nigdy nie ruszyla.

  **Kaskada:** `zfsbackup` **488/0** (478 recenzenta + 10 nowych), `restore`
  **171/0**, `stagger` **20/0**, `linkfields` **36/0**, `rerun` **16/0**,
  `rux` **37/0**. `localbackup` na CI — udokumentowany jako niewiarygodny na tej
  stacji. `./test/impact.sh --verify` zielone.


- **DOMYSLNA ODPOWIEDZ NA NIEUDANY QUIESCE — ODWROCONA (2026-08-27).**
  Decyzja wlasciciela, doslownie: *"Przemyslalem i chce, zeby snapshots sie
  tworzyly domyslnie pomimo porazki flush buffers."*

  **Nieudany freeze BIERZE snapshot.** Crash-consistent, `_crash_` w nazwie,
  rc 8, zeby cron to zglosil. Bez zadnego kwalifikatora, na kazdym tierze,
  w obu silnikach. Nic w mechanice sie nie ruszylo — ruszyla strona, w ktora
  patrzy `QUIESCE_DEGRADE`, gdy nikt nic nie powiedzial: `1`, nie `0`.

  **`,strict` to droga powrotna**, per tier, i przywraca poprzednie zachowanie
  co do joty: zaden snapshot, przebieg pada. Nie jest formalnoscia — to
  wlasciwa odpowiedz dla danych, ktorych procedura odtwarzania zaczyna sie od
  wyrzucenia kopii crash-consistent.

  **`,degrade` dalej sie parsuje** i prosi teraz o to, co dostanie i tak.
  Zostawione swiadomie: `profiles/prod.conf` i kazdy crontab wygenerowany od
  2026-08-26 go niosa, wiec kwalifikator, ktory zaczalby sie wywalac, zamienilby
  godzinny `git pull` w awarie calego estate. Praktyczna konsekwencja: **zadna
  linia w produkcji nie zmienia dzis znaczenia** — zmieniaja je wylacznie tiery
  z golym `-q <mode>`, ktore teraz degraduja zamiast odmawiac.

  **Defekt, ktory ta zmiana WYTWORZYLA i ktory zlapala wlasna suita** — wart
  zapamietania, bo nie widac go w diffie. Kazde z szesciu miejsc odmowy mialo
  ksztalt `bramka && return 1` / `log 0 "<co jest zle + polecenie naprawcze>"` /
  `exit 3`, wiec zdanie z LEKARSTWEM bylo osiagalne wylacznie na sciezce, ktora
  odmawiala. Przy starym domysle to byla sciezka typowa i nikt tego nie zauwazyl.
  Przy nowym operator dostaje `DEGRADING` co noc, snapshot `_crash_` co noc,
  i nigdy zdania, ze konto nie ma `--allow-quiesce` albo ze gosc jest poza
  whitelista. Backup, ktory dziala dalej i po cichu gubi powod, dla ktorego jest
  gorszy, zamienia naprawialny blad konfiguracji w trwaly. Diagnoza jest teraz
  logowana PRZED bramka we wszystkich szesciu miejscach; asercja jest
  strukturalna (kazde wywolanie bramki musi byc poprzedzone `log 0`, plus
  asercja liczby miejsc, zeby skasowanie ich nie przeszlo), z kontrola mutacyjna.

  **`settings.ini` ISTNIEJE od tego dnia.** `settings_get` czytalo ten plik od
  2026-08-26 na kazdym hoscie i na kazdym go nie znajdowalo, wiec oba jego klucze
  zyly tylko w kodzie, ktory ich szukal. `deploy.sh` Faza 2a zapisuje go raz
  (`settings_write_default` w `lib-cron.sh`), 0644 — bo czyta go KONTO
  DELEGOWANE, a nieczytelny plik nie pada, tylko po cichu wraca do wbudowanego
  domyslu. **Nigdy nie nadpisuje**: plik istnieje po to, zeby go recznie
  edytowac. Wszystkie klucze w szablonie sa zakomentowane, wiec swiezo wdrozony
  host zachowuje sie dokladnie tak jak przed jego pojawieniem sie.
  `quiesce` jest zakomentowany z konkretnego powodu, wypisanego w samym pliku:
  domysl hosta trafia do KAZDEGO tiera, ktory nie podal wlasnego, a w `prod.conf`
  to jest tier HOURLY, ktory nie ma quiesce swiadomie. Odkomentowanie wlacza
  zamrazanie kazdego goscia 24 razy na dobe.

  **Dowody:** `test/quiesce` **265/0** (gramatyka z obiema polowami, domysl
  biblioteki czytany w czystym srodowisku z kontrola srodowiskowa, laczenie
  parsera z bramka end-to-end, przetrwanie diagnozy przy degradacji + kontrola
  mutacyjna); `test/cron` **132/0** (sekcja Z: round-trip przez prawdziwe
  `settings_get`, a nie grep szablonu; swiezy plik nie zmienia nic, odkomentowany
  klucz dziala); `test/run.sh` **96/0** (nowy golden `quiesce-strict` z kontrola
  negatywna w tym samym fixture, dwa nowe przypadki negatywne); `test/runsuffix`
  **15/0**. Reszta baterii: CI.

- **DEGRADACJA NIEUDANEGO QUIESCE — ZROBIONA (2026-08-26).**
  `docs/design/quiesce-degrade.md` opisuje teraz stan zbudowany, nie plan.
  **Domysl odwrocony dzien pozniej — patrz wpis powyzej.** Ponizszy opis
  mechaniki jest dalej aktualny; nieaktualne jest tylko to, ktora z dwoch
  odpowiedzi dostaje tier, ktory nie powiedzial nic.

  **Co to naprawia, zmierzone:** w labie pve9/pve1/pve2 (2026-08-25) profil
  `prod` wyprodukowal ZERO snapshotow dla trzech z czterech tierow, bo konto
  delegowane nie moglo dosiegnac goscia, a kazdy tier proszacy o `-q` odmawia
  zamiast zrobic snapshot. Dla `_hourly` to jeden interwal z dwudziestu czterech.
  Dla `_daily`, `_weekly` i `_monthly` to trwaly artefakt, po ktory ten tier
  istnieje.

  **Co się zmienilo:** pole `quiesce` przyjmuje opcjonalny kwalifikator
  `,degrade` — per tier, zadeklarowany z gory. **Bez niego nie zmienilo sie
  nic**: kazda dotychczasowa odmowa zachowuje sie dokladnie tak jak wczesniej,
  i to jest asercja, na ktora suita wydaje najwiecej linii (ta sama awaria
  z kwalifikatorem i bez, w kazdym miejscu odmowy, lokalnie i zdalnie).
  Z nim: nieudany quiesce najpierw **wycofuje** wszystko, co ten przebieg
  zdazyl utworzyc, i **rozmraza** wszystko, co zamrozil — i dopiero z tak
  udowodnionego czystego stanu bierze CALY zestaw ponownie jako
  `automated_daily_crash_<stamp>`, przesyla go normalnie, weryfikuje ladowanie
  i konczy sie **rc 8**, wiec notifier crona to zglasza.

  **Czego `,degrade` NIE usprawiedliwia** (fatalne z kwalifikatorem tak samo jak
  bez): nieudany thaw, zastany cudzy freeze, oraz rollback, ktory nie zdolal
  usunac snapshotow tego przebiegu. Osobno fatalny zostaje tryb, ktory nigdy nie
  pasuje do goscia (`agent` na kontenerze, `sync` na VM) — to blad konfiguracji,
  ktory sam sie nie naprawi, a degradowanie go mowiloby operatorowi, ze jego
  goscie sa quiesced tak dlugo, jak dlugo ten config przetrwa.

  **Nazwa jest stala i niekonfigurowalna**, budowana jednym helperem dla PUSH
  i PULL. Znacznik `_crash_` stoi miedzy rodzina a znacznikiem czasu, i obie
  polowy tego zdania sa nosne: `delsnaps.sh` dopasowuje rodzine PREFIKSOWO
  (wiec retencja dalej ja przycina), a porzadkuje po `zfs list -s creation`
  (wiec wstawka niczego nie przestawia). `check-snap-age.sh` z tego samego
  powodu zostaje ZIELONY — to swiadomy podzial pracy, nie dziura: monitor wieku
  odpowiada na pytanie „czy jest swiezy snapshot", a to, ze jest
  crash-consistent, raportuje status przebiegu i mail. Monitor zglaszalby to
  co 15 minut przez cale zycie snapshotu, czyli powodz, ktora ten estate juz raz
  zmierzyl i usunal.

  **`prod.conf`**: `auto,degrade` na daily/weekly/monthly; `hourly` dalej bez
  quiesce w ogole, bo godzinny freeze zatrzymywalby kazdego goscia 24 razy
  dziennie, a strata jednego interwalu z dwudziestu czterech nie jest tym, po co
  to powstalo.

  **`settings.ini` hosta** podaje `quiesce` WYLACZNIE wtedy, gdy tier nie podal
  zadnego. Nie moze nadpisac wartosci jawnej: tier, ktory mowi `auto,strict`,
  dalej znaczy `auto,strict`, cokolwiek jest w pliku hosta. `settings_get`
  przeniesione z `zfs-backup.sh` do `lib-cron.sh` — jedyny plik, ktory
  `zfs-backup.sh` i `gen-cron.sh` i tak oba laduja, wiec nie moga sie roznic co
  do tego, co powiedzial host. Sam plik powstal dopiero 2026-08-27 — patrz wpis
  o odwroceniu domyslu.

  **POPRAWKA tego samego dnia, znaleziona w recenzji:** zdanie ponizej bylo
  bledne i warto zapamietac, na czym polegal blad rozumowania. Kody wyjscia
  zdalnego skryptu rozrozniaja **CZYSTOSC STANU**, nie **PRZYCZYNE**. `3` i `5`
  oba znacza „host jest taki, jakim go zastalismy" — i to jest dokladnie warunek
  wstepny dla zestawu crash-consistent. Ale dwie odmowy, ktore kontrakt trzyma
  fatalnymi — zastany cudzy freeze i tryb niepasujacy do goscia — TEZ sa czyste.
  `prep_one` zwracalo 1 dla kazdej awarii, agregator robil z tego `exit 5`,
  a strona lokalna degradowala kazde 5. Efekt: ta sama konfiguracja odmawiala
  przy zastanym freeze na PUSH i degradowala go na PULL.
  Poprawione: `prep_one` zwraca 2 dla przyczyn niedegradowalnych, agregator
  liczy dwie klasy osobno, fatalna wygrywa — `exit 9`, ktorego mapowanie lokalne
  nie degraduje. Przy okazji zamkniete: `info=$(gq_status "$id")` gubilo status
  polecenia, wiec nieczytelny status dawal puste `kind` i wpadal w galaz
  „no guest — skipping" ze statusem SUKCES; helper, ktory nie umial odpowiedziec,
  wygladal jak host bez czego zamrazac.
  Testy, ktore tego nie zlapaly, podstawialy gotowy rc — dowodzily wylacznie, ze
  5 staje sie 8, i nigdy nie pytaly, **co** staje sie piatka. Nowe dyskryminatory
  URUCHAMIAJA zdalny klasyfikator i przenosza jego faktyczny kod przez mapowanie
  lokalne; dwie istniejace asercje przesuniete z 5 na 9 swiadomie, bo to jest ta
  zmiana kontraktu. Kontrola negatywna: 12 asercji pada na bibliotece sprzed
  poprawki.

  **Zdalna polowa wymagala jednej zmiany klasyfikacji** w skrypcie wysylanym
  przez ssh, i to jest najwazniejsza rzecz do zapamietania z tej laty. Pierwsze
  podejscie wstawilo wywolanie bramki do tamtego heredoca — czyta sie jak kod
  lokalny, a nie jest nim; po tamtej stronie nie istnieje zadna funkcja
  z biblioteki, wiec zdalny quiesce przestalby dzialac przy pierwszym uzyciu.
  Wycofane przed wyslaniem. Okazalo sie, ze kontrakt kodow wyjscia tamtego
  skryptu JUZ rozroznia stany, o ktore chodzi, i to strukturalnie: `3` to
  odmowa przed zamrozeniem czegokolwiek, `5` to awaria z czystym rollbackiem
  i thaw (bo porazka ktoregokolwiek z nich zamienia `5` na `7` albo `6`).
  Wiec cala decyzja to mapowanie rc po stronie lokalnej.

  **Dowody:** `test/quiesce` +53 asercje (tabela gramatyki z obiema polowami,
  bramka z trzema kontrolami mutacyjnymi, wszystkie siedem zdalnych kodow
  w obu kierunkach); `test/runsuffix` — zgodnosc nazwy PUSH/PULL z kontrola
  negatywna; `test/run.sh` — fallback z `settings.ini` plus kontrola, ze NIE
  rozszerza jawnego `auto`; nowy golden `quiesce-degrade` i cztery przypadki
  negatywne w `gen-cron.sh`.
  **Czego nie udowodnil zaden test lokalny:** przebiegu od konca do konca —
  zdegradowany snapshot, ktory przechodzi transfer i konczy sie rc 8. Ta maszyna
  nie ma ZFS. To jest obowiazek NA ZYWO i jest opisany nizej.

- **LAB ZBUDOWANY OD ZERA: pve9 <- pve1 (2026-08-26).**
  Szczegoly i znaleziska: `docs/project/LAB-REBUILD-20260826-FINDINGS.md`.

  **Powod:** dwa argumenty projektowe o odtwarzaniu oparlem na parze
  pve1<->pve9, a oba stalu na faktach, ktore byly **sladem po moich wlasnych
  labach** — zaufanie root<->root (bo laby chodzily jako root) i „kolektor laczy
  sie co godzine" (pve9 mial ZERO zadan, wszystkie rekordy `STATE=removed`).
  Projekt oparty na skazonym labie pasowalby do labu.

  **Stan po przebudowie:** pve9 bez ani jednego sladu relacji i z pusta pula;
  pve1 bez sladow lab-owych, produkcja nietknieta, crontaby potwierdzone hashem.
  Zaufanie ssh miedzy hostami usuniete w OBIE strony i sprawdzone.

  **Nowa relacja `lab1`**, zalozona sciezka BEZ zaufania (`--manual-join`):
  kolektor nie mogl siegnac do zrodla, wiec wygenerowal wsad, wsad zostal
  przeniesiony, a zrodlo samo zatwierdzilo swoj zakres.

  ```
  pve1 hdd/labsrc/vm-900-disk-0 (6 MB) -> pve9 hdd/labcoll/192.168.28.9/hdd/labsrc/...
       hdd/labsrc/vm-900-disk-1 (4 MB)
  ```

  Dwa dyski jednego goscia — celowo, bo to jest przypadek, ktorego potrzebuje
  odtwarzanie. Seed potwierdzony GUID-em na trzech datasetach, nie komunikatem.

  **Co lab od razu rozstrzygnal:** planer mowi „zrodlo jest ZDALNE". Kolektor
  siega do zrodla kontem `zfsbackup-pve9`; **w druga strone nie ma nic**.
  Odtwarzanie w trybie pull wymaga kanalu, ktorego nie ma i ktorego zaden
  obecny czasownik nie zaklada — i to jest teraz fakt o prawdziwej relacji.

  **Cztery znaleziska**, w tym jedno o naszym silniku: wyciek holda
  `zfssnapall_inflight` blokowal sprzatanie przez cztery dni.

  **F3 NAPRAWIONE (2026-08-26).** Diagnoza wyszla inaczej, niz zakladalem:
  silnik trzyma hold CELOWO, gdy transfer padl z tokenem wznowienia — nastepny
  przebieg potrzebuje dokladnie tego snapshotu, i to jest poprawne. Wada polega
  na tym, ze **nikt nigdy nie zauwaza, gdy ten nastepny przebieg juz nie
  przyjdzie**, bo relacje rozebrano. Czyli naprawa nalezy do sprzataczki, a nie
  do zamrozonego silnika — i silnika nie tknieto.

  `clean-relationships.sh` sprawdza teraz **caly host**, niezaleznie od listy
  relacji (bo wyciek JE PRZEZYWA, wiec cokolwiek kluczowane na relacji minie
  dokladnie ten przypadek). Jedno wywolanie `zfs get -t snapshot userrefs`
  znajduje kazdy trzymany snapshot; `zfs holds` biegnie tylko dla nich, wiec
  zdrowy host kosztuje jedno wywolanie.

  **Zglasza tylko NASZ tag.** Hold pvesr na replikowanym datasecie jest nosny
  dla cudzej replikacji, a ten projekt juz zmierzyl, ile kosztuje ruszenie go.
  **I nie zwalnia automatycznie** — narzedzie nie odrozni wyciekniętego holdu od
  chroniacego transfer, ktory wlasnie biegnie. Nazywa, podaje dokladna linie,
  konczy. Ta sama zasada co przy danych.

  Audyt **nie konczy sie czysto**, gdy cos jest trzymane: „nothing orphaned",
  podczas gdy dataset po cichu nie daje sie przyciac, to falszywy spokoj, ktoremu
  to narzedzie ma zapobiegac.

  **F1 i F2 NAPRAWIONE (2026-08-26).** Separator w rekordzie to ESCAPE'OWANA
  SPACJA (`%q`), wiec dzielenie po bialych znakach dawalo `hdd/a/tree\` —
  nazwe, ktorej nie da sie wkleic do `zfs destroy`, czyli dokladnie to, po co ta
  linia istnieje. Dekodowane BEZ `eval` i `source`: plik pozostaje danymi.
  Bezpieczne, i to nie z zalozenia — **zmierzone**, ze nazwa datasetu ZFS nie
  moze zawierac ani spacji, ani przecinka (`zfs create hdd/x,y` odrzucone), wiec
  `\ ` w tym polu moze byc wylacznie separatorem. Kazdy INNY backslash znaczy,
  ze wartosc nie jest tym, czym kod ja uwaza — i jest oznaczana jako SUSPECT,
  zamiast po cichu do polowy odkodowana.

  F2: audyt **mowi teraz, czy dane jeszcze sa** (`still on disk` / `already
  gone`). Wczesniej czasownik niszczacy weryfikowal, a czytajacy nie.

  **Wada, ktora sam przy tym wprowadzilem i ktora zlapala istniejaca asercja:**
  etykiete doklejalem do POLA, ktore dalej konsumuje purge — podawal ja do
  `zfs list`, wiec pytal o nieistniejaca nazwe i raportowal istniejacy dataset
  jako ALREADY GONE. Etykieta nalezy do miejsca, ktore WYPISUJE, nie do tego,
  ktore produkuje. Przeniesiona do reportera.

  `test/cleanrel` 47/0. Kontrola negatywna na wersji sprzed poprawki: **5
  asercji pada**, a „dwa datasety" przechodzi tez tam — bo stare dzielenie tez
  dawalo dwa wpisy, tylko pierwszy zepsuty. Dyskryminatorem jest backslash, nie
  liczba wpisow.

  **Zaostrzone po recenzji (2026-08-26).** „Prawdopodobnie wyciekl" nie jest
  werdyktem, a WIEK niczego nie dowodzi. Hold jest uznawany za OSIEROCONY
  dopiero wobec dowodow, ktore zapisuje sam silnik:

  | fakt | skad |
  |---|---|
  | biegnie silnik | tablica procesow (`snapsend`/`snapget`/`zfs send`) |
  | rekord in-flight nazywa TEN snapshot | `<silnik>.inflight-snap.<klucz>` w katalogu blokad |
  | lokalny `receive_resume_token` | `zfs get` |

  Trzy werdykty: **IN-USE** (rekord wskazuje ten snapshot), **UNPROVEN** (cos
  biegnie albo jakis transfer chce kontynuowac — fail-closed) i **ORPHANED**.
  **GRANICA POWIEDZIANA WPROST:** token wznowienia jest wlasnoscia CELU, wiec
  przy relacji pull lezy na innym hoscie i stad go nie widac — raport to mowi,
  zamiast sugerowac, ze sprawdzil wszystko.

  **Zwalnianie tylko w jawnej sciezce `--purge --yes`**, z nazwaniem kazdego
  snapshotu; audyt nie zwalnia nigdy. Sprawdzenie procesow idzie przez
  `HOLD_PS_CMD`, zeby wynik testu nie zalezal od tego, czy na maszynie
  testujacej akurat cos leci.

  **Wada znaleziona przez wlasny test:** `--purge-orphans` wracalo wczesniej,
  gdy nie bylo osieroconych RELACJI — wiec host z wyciekniętym holdem i bez
  osieroconych relacji nie mial jak go zwolnic. Czyli **dokladnie przypadek
  pve9, od ktorego cale to sprawdzenie sie zaczelo**.

  **P1 ZNALEZIONY W RECENZJI I NAPRAWIONY (2026-08-26).** `/var/run` **nie
  przezywa restartu**. Po reboocie zrodla plik in-flight znika, a hold ZFS
  **i zdalny token wznowienia zostaja**. Pierwsza wersja widziala wtedy: brak
  procesu, brak lokalnego tokenu, brak rekordu → ORPHANED → i zwalniala snapshot,
  ktorego zdalne wznowienie wciaz potrzebowalo.

  Napisalem w raporcie, ze zdalnej strony stad nie widac — i mimo to orzekalem po
  jej drugiej stronie. **Nazwanie granicy nie czyni decyzji przez nia bezpieczna.**
  Brak pliku w tmpfs to brak dowodu, nie dowod braku.

  Poprawione: **ORPHANED nie jest juz wnioskowane automatycznie.** Werdykt brzmi
  UNPROVEN z podaniem powodu — „nic TUTAJ tego nie rosci, ale odbiorcy stad nie
  widac". Zwalnianie przeniesione do `--release-hold=<snapshot> --yes`, gdzie
  czlowiek dostarcza osad, ktorego kod nie ma: wie, czy tamta relacja jeszcze
  istnieje. Wciaz odmawia, jesli cokolwiek widoczne STAD mowi, ze hold jest w
  uzyciu — pytamy o druga strone, nie o fakty, ktore maszyna juz ma.

  Audyt **nadal nie konczy sie czysto**, i to sie nie zmienilo wraz z werdyktem:
  hold, ktorego nie rosci nic biegnacego, blokuje `zfs destroy` i po cichu psuje
  retencje niezaleznie od tego, czyj jest.

  **Druga runda tej samej granicy.** `UNPROVEN` obejmowalo TRZY rozne przyczyny —
  biegnacy silnik, lokalny token, nieobserwowalny odbiorca — a bramka recznego
  zwolnienia odmawiala tylko dla `IN-USE`. Wiec `--release-hold --yes` zwolnilby
  hold takze wtedy, gdy transfer biegl LOKALNIE. Wlasny komunikat commita mowil,
  ze czlowiek odpowiada wylacznie za dalek**a** strone; kod tego nie egzekwowal.

  Poprawione: `hold_verdict` zwraca **kod przyczyny** (`inflight`, `engine`,
  `localtoken`, `remote`), a bramka czyta kod, **nie tresc komunikatu**.
  Przejsc moze wylacznie `remote` — jedyny przypadek, w ktorym lokalnie jest
  czysto, a nieznana jest tylko druga strona. Kod nierozpoznany tez odmawia.

  Uwaga techniczna warta zapamietania: to nie moze byc zmienna globalna —
  `hold_verdict` jest wolane w `$( )`, czyli w podpowloce, wiec cokolwiek
  ustawione w srodku by zginelo. Kod jedzie w wypisywanym tekscie jako osobne
  pole.

  `test/cleanrel` 72/0, w tym kontrprzykład recenzenta wprost (hold istnieje,
  brak pliku in-flight, brak procesu — stan po restarcie — a `--purge-orphans
  --yes` **nie wola `zfs release`**) oraz dwa dyskryminatory na recznym
  czasowniku: biegnacy silnik i lokalny token **nie daja sie nadpisac**.

  Sprawdzone na zywo na pve9 obiema kontrolami: hold zalozony → zgloszony,
  wyjscie 3; hold zwolniony → cisza, wyjscie 0. `test/cleanrel` 38/0, w tym
  kontrola, ze **sam wyciekly hold wystarczy**, zeby audyt nie byl czysty, i ze
  cudzy tag jest niewidoczny. Tag dopisany do kontraktu `hold-tag` w deps.conf —
  teraz pilnuje go graf, bo tag, ktory sie rozjedzie, sprawi, ze ten raport po
  cichu nie pokaze nic, co jest nie do odroznienia od zdrowego hosta.

- **RESTORE: trzy korekty po recenzji (2026-08-26).**

  **`--at` klasyfikowalo inny snapshot, niz pokazywalo.** Podglad drukowal
  `WYBRANO WANTED`, a `restore_plan_strategy` liczyl strategie na NAJNOWSZYM
  snapshocie z pelnej listy — takze takim z PO zadanej chwili. Dwie odpowiedzi na
  jedno pytanie w jednym ekranie, bez sposobu na rozpoznanie, ktorej dotyczy
  potwierdzenie. Teraz do klasyfikatora idzie wylacznie wiersz wybrany przez
  `--at`, a gdy `--at` nic nie wskazal, strategia w ogole sie nie liczy.
  Znalezione przy tym samodzielnie: naglowek nad strategia dalej glosil
  „domyslna polityka: NAJNOWSZY". Poprawna odpowiedz pod falszywym podpisem to
  nadal falszywy podglad, wiec naglowek dostal parametr.

  **Wykluczenie `--source`/`--target` wycofane.** Recenzent uznal, ze przekroczyl
  role: to byla decyzja Ownera, nie jego. Dzialaja trzy formy — sam `--source`,
  sam `--target`, albo **oba jawnie**. Podanie obu to NIE przemapowanie:
  listy musza miec te sama dlugosc, sa czytane parami po kolei, a kazda para musi
  zgadzac sie z zapisem relacji. Parami, nie zbiorami — inna kolejnosc po dwoch
  stronach znaczy, ze operator powiedzial cos, czego nie chcial, a ciche
  posortowanie zakryloby dokladnie ta pomylke.

  **Zarzut o rozcinaniu wyniku po literze `t` zamiast po tabulatorze — odparty.**
  W pliku jest prawdziwy tabulator; zmierzone, obie strony wychodza poprawnie.
  Recenzent czytal diff, w ktorym tab wyglada jak `	`. Ale jego uwaga o TESCIE
  byla trafna: asercja liczyla wiersze zamiast sprawdzac wartosci. Zapis zmieniony
  na jeden jawny odczyt, a test na dokladne wartosci obu stron.

  Przy okazji dwie wady w moich wlasnych testach: stara asercja wymuszajaca
  wycofana regule, oraz kontrola szukajaca `Zrodlo:     roo` jako PODCIAGU —
  a poprawna wartosc `root@pve2:...` tez to zawiera, wiec test padal na dzialajacym
  kodzie. Zakotwiczona do konca linii.

  **Poprawka do poprawki (ta sama recenzja, druga runda).** Przekazanie strategii
  WYLACZNIE wybranego wiersza naprawilo cel i zepsulo baze: ta sama lista jest
  przechodzona DRUGI raz, zeby znalezc najnowszy snapshot, ktorego GUID istnieje
  takze na zrodle — czyli wspolna baze dla przyrostu. Jeden wiersz = zero
  kandydatow, wiec dataset z dobra starsza baza byl klasyfikowany jako „FULL na
  ISTNIEJACE zrodlo, wspolnej bazy NIE MA". Dla czasownika niszczacego to jest
  odwrotnosc prawdy w niebezpieczna strone.
  Naprawa: strategia dostaje liste odfiltrowana do `creation <= creation(wybrany)`.
  Maksimum tego, co zostaje, JEST wybranym punktem (remis na tej sekundzie i tak
  jest wczesniej odrzucany), a wszystkie legalne starsze kandydatury zostaja.
  Kontrola negatywna na wersji sprzed poprawki: 3 asercje padaja, a asercja o
  samym celu dalej przechodzi — czyli rozrozniaja ten defekt, nie alarmuja na
  wszystkim.

  `test/restore` 162/0.

- **RESTORE: `--at` — punkt odtworzenia w czasie zegarowym (2026-08-26).**
  `restore pve2 --at "2026-08-10 12:00"`. Operator mysli chwila, nie nazwa
  snapshotu.

  **Wybor idzie po wlasciwosci ZFS `creation`, NIGDY po nazwie.** Planer juz
  krzyczy, gdy te dwie rzeczy roznia sie o wiecej niz dwie minuty; wybieranie po
  nazwie znaczyloby cicho brac opowiesc zamiast faktu.

  Trzy wyniki na dataset i wszystkie trzy sa wypisane: **rozstrzygniety** (zadany
  czas, wybrany snapshot, jego prawdziwy `creation` i GUID obok siebie),
  **brak czegokolwiek dosc starego** (blad TEGO datasetu, reszta dalej
  planowana), **remis** na najpozniejszym `creation` (odmowa wyboru — nazwa nie
  jest rozstrzygajaca).

  Naglowek `PER-DATASET FRONTIER -- NIE atomowy stan calej relacji` idzie raz,
  nad planem, a nie drobnym drukiem: cztery dyski jednej VM to dokladnie ten
  przypadek, w ktorym ktos zalozy, ze dostal jedna chwile.

  Niepelny plan konczy sie **statusem niezerowym** (decyzja Ownera nr 7) — status
  wyjscia to jedyna czesc tego, ktora czyta cron.

  `test/restore` 143/0. Przypadek nosny: szukany snapshot nie jest ani
  najnowszy, ani najstarszy — implementacja biorąca ostatni, najnowszy albo
  leksykalnie najwiekszy nie przechodzi nic z tego bloku.

- **RESTORE: zakres odzyskiwania — relacja osobno, datasety po przecinkach
  (2026-08-26).** Decyzja wlasciciela: VM z czterema dyskami wirtualnymi to
  cztery datasety i JEDNO odzyskiwanie. Cztery polecenia znaczylyby cztery
  podglady, cztery potwierdzenia niszczace i okno, w ktorym maszyna jest
  odtworzona w polowie — dla czegos, co dla czlowieka jest jednym obiektem.

  ```
  zfs-backup.sh restore pve2 --target rpool/data/vm-101-disk-0,rpool/data/vm-101-disk-1
  ```

  **Przecinek jest bezpieczny ZMIERZONYM faktem, nie konwencja.** ZFS nie
  dopuszcza go w nazwie datasetu (pve9, 2026-08-26: `invalid character ','`),
  wiec nie moze wystapic wewnatrz elementu listy i rozciecie po nim nie zniszczy
  legalnej nazwy. Tego wlasnie brakuje dwukropkowi — dwukropek JEST legalny
  w nazwie, i to on zrobil z `pve2:rpool/data` przypadek dwuznaczny.

  **Skutek uboczny, wazniejszy niz sama lista:** nazwa relacji stoi teraz sama,
  a dataset przychodzi flaga — wiec cala dwuznacznosc dwukropka **znika**, a nie
  zostaje rozstrzygnieta. Plik `OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` jest
  oznaczony jako czesciowo nieaktualny, nie przepisany.

  **Jeden namespace na wywolanie** (recenzent, 2026-08-26): `--source`
  i `--target` wykluczaja sie, cala lista musi sie rozwiazac PRZED podgladem,
  a brak elementu, niejednoznacznosc, duplikat wejscia albo dwa elementy
  prowadzace do tego samego celu to odmowa **bez zadnej mutacji**. Usuwa to
  konkretna pomylke: operator nazywa dwa dyski VM po stronie kolektora, dwa po
  stronie hosta i dostaje plan, ktory wyglada kompletnie.

  Zaimplementowana jest **polowa rozstrzygajaca zakres**; plan jest tylko do
  odczytu, wiec zadne drzwi niszczace sie tu nie otwieraja. Rozdzial namespace
  siedzi w rdzeniu dopasowania (`restore_resolve_try` dostal argument
  namespace), a stara forma pozycyjna dalej podaje pusty — bo powiedzenie, ktora
  strone sie ma na mysli, jest calym sensem uzycia flagi.

- **RESTORE: nazwa relacji musi wskazywac JEDNA relacje (2026-08-26).**
  `zfs-restore.sh` odmawia przed czymkolwiek, jesli ktorys rekord w
  `/etc/zfs-snapshot-all/clients/` deklaruje `CLIENT_NAME` inny niz wlasna nazwa
  pliku. Powod jest prosty: adres `pve2:rpool/data` znaczy „relacja pve2", a
  relacja to nazwa nadana przez operatora — moze wskazywac na dowolna maszyne,
  takze na pve9. Jesli dwa pliki mowilyby „nazywam sie pve2", narzedzie
  wybraloby ktorys i odtworzylo nie to, co trzeba. Na pve9 lezy ponad
  piecdziesiat rekordow, wiec to nie jest teoretyczne.

  Jedno porownanie wystarcza za caly warunek: dwa pliki w jednym katalogu nie
  moga miec tej samej nazwy, wiec zgodnosc z nazwa pliku JEST jednoznacznoscia.
  Petla szukajaca duplikatow byla martwym kodem w kostiumie zabezpieczenia i
  zostala usunieta.

  **Czego NIE zmieniono:** samego adresowania. `restore_resolve_token` juz
  rozstrzyga dwuznacznosc dwukropka i juz odmawia adresowania po hoscie
  (R-025) — ostrzej niz proponowala regula recenzenta, i zgodnie z decyzja
  Ownera nr 1 (pull-first). Drugi parser bylby drugim sposobem czytania tego
  samego argumentu.

- **ETAP PROFILI, faza 2: JEDEN PLIK NATYWNY + profil `prod` odwzorowujacy
  produkcje (2026-08-25).**

  Decyzja wlasciciela po dyskusji z recenzentem: **jeden plik dla operatora,
  bez tworzenia nowego jezyka**. Profil to `profiles/<nazwa>/profile.conf`;
  trzy dotychczasowe artefakty pozostaja, ale jako **cel kompilacji**, nie jako
  interfejs. Nikt nie powinien wiedziec, ze profil to trzy pliki, zeby zmienic
  retencje.

  **Co wziete z propozycji recenzenta:** jeden plik, naglowek `[profile]`
  z wersja, oraz ergonomiczne `keep = 24` — tlumaczone na `retain = -H24` przy
  renderowaniu, z **kanonicznej** nazwy tieru, przy uzyciu tabeli liter
  pobranej z `gen-cron.sh --dump-tier-letters` (nowe), a nie jej kopii.

  **Co zostawione ze swojego:** natywne nazwy sekcji i pol (jeden autorytet
  schematu), oraz — co wazniejsze — **tworzenie i kasowanie nie sa zrosniete**.
  Fuzja `[tier:]` z propozycji recenzenta umie opisac produkcje, ale **nie umie
  opisac `default`**, ktory tworzy JEDNA rodzine i przycina ja CZTEREMA
  licznikami w jednej drabinie GFS.

  **Dowod, ze zmiana formatu niczego nie zmienila:** ten sam plan wyrenderowany
  z builda `main` (trzy pliki) i z jednoplikowego — **94 linie kazdy,
  IDENTYCZNE**.

  **`profiles/prod/profile.conf`** — przepisany z zywego
  `jobs.pve1.v4.conf` (odczyt 2026-08-25), nie zaprojektowany:

  | tier | prefiks | retencja | quiesce | progi |
  |---|---|---|---|---|
  | hourly | `automated_hourly_` | 24 | — | 90m / 3h |
  | daily | `automated_daily_` | 7 | **auto** | 30h / 48h |
  | weekly | `automated_weekly_` | 4 | **auto** | 9d / 12d |
  | monthly | `automated_monthly_` | 6 | **auto** | **brak** (zdjete 2026-07-22, strzelalo co 15 min) |

  Brak progow miesiecznych jest przepisany **swiadomie**: profil, ktory po cichu
  by je przywrocil, przywrocilby powodz. Nie ma tez bloku `[prune]` — kazdy tier
  przycina wlasna rodzine wlasnym `prune_schedule`, wiec nie ma osobnej drabiny
  do wyemitowania.

  **`detect_profile_gfs` czyta teraz KSZTALT, nie nazwe.** Szukalo doslownego
  `[template:standard_hourly]` i pytalo, czy ta sekcja ma `prune_schedule` — co
  dzialalo wylacznie dla configow pisanych przez wbudowany `default`, a dla
  profilu nazwanego jak produkcja (`hourly`, `daily`) odpowiadalo „drabina",
  choc to plaski uklad per tier. Teraz rozstrzyga jeden fakt: czy szablon
  TWORZY rodzine i PRZYCINA ja w tym samym miejscu. Zmierzone w czterech
  kierunkach: drabina -> GFS, produkcyjny plaski -> plaski, **stary
  `standard_hourly` plaski -> plaski** (zachowane), pusty config -> GFS.

  **ZNANE OGRANICZENIE, nazwane wprost: rozrzut po osi czasu MILCZY dla profilu
  wielotierowego.** Zmierzone: `default` -> `send_expr='1 * * * *'` (rozrzut
  dziala), `prod` -> `send_expr=''` (rozrzut nie robi nic). Przyczyna jest
  zaprojektowana: pole sekcji nadpisuje KAZDY tier, ktory `use_template`
  wymienia, wiec wpisanie jednej minuty splaszczyloby dzienny, tygodniowy
  i miesieczny na godzinne — pierwsza wersja rozrzutu tak wlasnie robila
  i recenzja to zlapala. Skutek: kilka relacji z profilu `prod` na jednym
  kolektorze uderzy w te same minuty.

  **Rozwiazanie jest znane i tanie**, tylko nie tutaj: `resolve_field_tiered`
  jest juz GENERYCZNE (sprawdza `<pole>_<tier>` na sekcji) i dzis wolane
  wylacznie dla `flags`. Wpiecie go dla `send_schedule`/`prune_schedule`
  pozwoli rozrzutowi pisac minute **per tier** (`send_schedule_hourly = 44 * * * *`),
  zachowujac kadencje kazdego tieru. Osobny krok, bo wymaga liczenia kolizji
  w trzech roznych oknach czasowych (godzina, doba, tydzien) — nowa logika,
  ktorej nie wolno mieszac z transkrypcja.

- **ETAP PROFILI, krok 5: `migrate-profile --profile=NAZWA`, i dziura, ktora
  przy tym wyszla (2026-08-25).**

  Cel byl prosty: „zaorac konfiguracje nowym profilem" nie mialo komendy.
  `migrate-profile` istnialo, ale z **zaszytym** celem — legacy plaska retencja
  -> drabina GFS — bo taka byla jedyna migracja w chwili jego powstania.
  Admin chcacy przeniesc hosta z `default` na `prod` mial jedna droge: recznie
  edytowac config, czyli dokladnie to, przed czym ta komenda mial chronic.

  Uogolnienie wymagalo trzech rzeczy, ktore wersja zaszyta mogla pominac:

  1. **`PROFILE_GFS` opisuje ZAINSTALOWANY config, nie profil.**
     `detect_profile_gfs` czyta PLIK. W trakcie migracji to wciaz ksztalt,
     **od ktorego** uciekamy. Wersja zaszyta ustawiala `PROFILE_GFS=1` i miala
     racje, bo jej celem zawsze byla drabina. Dla dowolnego celu to znaczy, ze
     `--profile=prod` wchodzil w galaz drabiny, a profil plaski nie ma bloku
     `[prune]`, ktorym da sie ja wypelnic. Zmierzone, nie wydedukowane:
     gen-cron odrzucil kandydata komunikatem `[prune:...] has no use_template`.
     Teraz pytamy **cel**, tym samym detektorem, wycelowanym w wyrenderowane
     szablony profilu.
  2. **Sekcje `[prune:]` klienta sa zamiatane po MARKERZE, nie po sciezce.**
     Drabina GFS siedzi na **rodzicu** datasetow, wiec `remove_managed_sections`
     (dostaje sciezki datasetow) nie moze jej dosiegnac — a cala galaz emisji
     drabiny jest pod `if PROFILE_GFS`, wiec migracja DO profilu plaskiego nie
     uruchomilaby tez usuwania. `default -> prod` zostawilby stara drabine obok
     nowego prune per tier: **dwa sprzatacze na tych samych snapshotach**.
  3. **Osierocone szablony liczone przez referencje**, nie po nazwie.

  **Dziura, ktora przy tym wyszla — powazniejsza niz sama migracja.**
  `detect_profile_gfs` odpowiada na pytanie o KSZTALT („czy tiery sprzataja
  same siebie?"). Odmowa w `ensure_cron_config` czytala te odpowiedz, ale
  dotyczy pytania o NAZWE: zamrozonej rodziny `standard_*` sprzed
  nazw przestrzennych. `prod` jest plaski **z definicji**, wiec wygladal jak
  legacy. Skutek zmierzony sonda z kontrola pozytywna:

  | krok | wynik |
  |---|---|
  | pierwsza generacja z profilu `prod` | 4 szablony zapisane, OK |
  | **druga** generacja na tym samym configu | **FATAL: „uses the pre-GFS profile (standard_* still carries prune_schedule)"** |

  Czyli `prod` byl profilem **jednej relacji na host** — a komunikat nazywal
  rodzine, ktorej w tym pliku nie ma. Nie dotyczylo to wylacznie migracji:
  to jest zwykla sciezka `activate-client` dla drugiego klienta. Wyszloby na
  zywym kolektorze, przy drugiej relacji, za kilka miesiecy.

  Rozwiazanie: rozdzielic dwa pytania. `config_is_frozen_legacy` pyta o NAZWE
  (goly `standard_*` z `prune_schedule`), `detect_profile_gfs` dalej o ksztalt.
  Bramka jest **zwezona, nie usunieta** — kontrola negatywna dowodzi, ze
  prawdziwy pre-GFS config nadal jest odrzucany.

  **Plik kandydata nie przezywa juz odmowy.** Kazda komenda transakcyjna
  sprzatala swoja kopie robocza na wlasnych sciezkach bledu, ale zadna nie
  siega `die()` podniesionego **wewnatrz wywolanej funkcji** — powloka konczy
  sie spod wolajacego, a `.zfsbackup-work.XXXXXX` zostaje obok zywego configu
  z prawami 0644. Zmierzone na poprzednim commicie: **1 plik zostaje**. Sprzatanie
  wpiete w istniejacy handler `EXIT` (`_profile_arm_release` komponuje sie
  ostroznie z handlerem konsumenta; drugi trap bylby kompozycja za duzo), a
  `atomic_replace_and_install` zwalnia sledzenie na wejsciu — zwolnienie
  sciezki, ktora stala sie zywym configiem, byloby katastrofa przebrana za
  porzadki.

  `test/zfsbackup`: **+12** asercji (96a-96l), w tym cztery kontrole. Kontrola
  negatywna to pelne drzewo sprzed zmiany (`git archive HEAD`) z wlozonymi
  nowymi testami: **9 pada**, a trzy kontrole („nieznany profil odmawia",
  „prawdziwy legacy odmawia", „opublikowany config nie jest zamiatany")
  przechodza po obu stronach. Asercja o wycieku zostala przerobiona na config
  **legacy** wlasnie po to, by na starym buildzie padala z wlasciwego powodu, a
  nie na nierozpoznanej fladze.

  **Nie zrobione, nazwane:** migracja przepisuje rekordy klientow (`PROFILE=`)
  **po** podmianie configu, bo to jedyny kierunek, ktorego nie da sie uczynic
  atomowym; blad na tym etapie jest nazwany per rekord, nie polkniety.

- **ETAP PROFILI, krok 4: sprzeczna podloga `[excluded:]` jest ODMAWIANA, ale
  tylko w kierunku, ktory oslabia (2026-08-25).**

  Domyka rzecz, ktora trzykrotnie zglaszalem jako niedokonczona. Sekcja
  `[excluded:]` nie jest opinia profilu: `gen-cron` skleja wszystkie w JEDEN
  fragment `PROTECT_FLAGS` doklejany do **kazdej** linii prune w pliku. Jeden
  config nie moze wiec ogrodzic rodziny na dwa sposoby.

  Dotad przy istniejacej sekcji instalator podlog po prostu **pomijal** swoja —
  czyli pierwszy zainstalowany profil wygrywal na zawsze, a deklaracja drugiego
  byla cicho niewazna: operator czytajacy profil B widzial liczbe, ktora nigdzie
  nie obowiazuje.

  **Pierwsze podejscie odmawialo na kazdej roznicy i bylo zle.** Wywrocilo
  wlasnosc, ktora to drzewo juz raz rozstrzygnelo i przypielo testem: *„only
  ADDS a missing floor, never narrows an operator's stronger keep"*
  (REV-20260810-092). `keep` to **minimum**, wiec te dwie liczby nie sa
  symetryczne — wiecej ochrony jest bezpieczne, mniej nie:

  | sytuacja | zachowanie |
  |---|---|
  | ten sam `keep` | deduplikacja, cisza |
  | config chroni **mocniej** niz profil prosi | zostaje **wartosc operatora**, jedna linia do logu |
  | config chroni **slabiej** niz profil wymaga | **ODMOWA** nazywajaca obie wartosci i kierunek |
  | `keep` nieczytelny dla `gen-cron` | odmowa jako *nieczytelny*, nie jako „slabszy" |
  | sciezka dziedziczaca, config slabszy | **ostrzezenie**, nie odmowa — patrz nizej |
  | profil sprzeczny **sam ze soba** | odmowa juz przy walidacji, nazywajaca plik |

  Uzasadnienie kierunku: przy `config >= profil` zatrzymanie liczby z configu
  nie kasuje niczego, na czym cokolwiek polega, a administrator, ktory
  swiadomie podniosl podloge, zachowuje swoja decyzje. Przy `config < profil`
  relacja pobieglaby za strazą slabsza niz deklaruje jej wlasna polityka,
  a podniesienie podlogi tutaj przepisaloby komende prune **kazdej** relacji juz
  obecnej w pliku (Gate 2) — zadna z tych rzeczy nie jest nasza do wyboru.

  `keep = all` jest legalny dla `gen-cron` i jest najsilniejsza podloga, jaka da
  sie wyrazic. Porownywany jako **tekst** wygladal po prostu „inaczej" niz `9`
  i zostalby odrzucony jako konflikt; teraz jest **rangowany** i przebija kazda
  liczbe. Wartosc, ktorej `gen-cron` sam by nie przyjal, nie jest rangowana jako
  zero — bo „brak ochrony" udajacy „ochrone slabsza" to odmowa z niewlasciwego
  powodu albo, gorzej, przepustka.

  Na sciezce dziedziczacej przebieg **w ogole nie pisze podlog** — config ma juz
  polityke relacji, wiec nowa relacja dziedziczy ja dokladnie tak, jak jest
  zainstalowana. Odmowa uczynilaby tam host bezuzytecznym. Ale liczba z profilu
  nie obowiazuje, a milczenie pozwoliloby wierzyc, ze obowiazuje — wiec silniej
  ogrodzony config milczy, a slabszy daje ostrzezenie.

  **Trzy wady znalezione we wlasnej poprawce**, wszystkie przez czytanie
  komunikatu i testu zamiast ufania kodowi wyjscia: komunikat odmowy uzywal
  `$config`, podczas gdy w tej funkcji zmienna nazywa sie `$file` — pod `set -u`
  przebieg umieral **z niewlasciwego powodu**; sprawdzanie i pisanie bylo
  w jednej petli, wiec konflikt na drugiej rodzinie odmawial po dopisaniu
  pierwszej, a komunikat twierdzil, ze nic nie zmieniono (teraz sa **dwa
  przebiegi**: najpierw sprawdzane sa wszystkie podlogi, dopiero potem pisana
  ktorakolwiek — bramka, ktora mutuje zanim odmowi, nie jest bramka); i sama
  regula symetryczna, ktora zlapal dopiero `test/zfsbackup` w CI.

  `test/profiles`: **66/0** (+8), z asercjami na oba kierunki, na `all`
  i na wartosc nieczytelna. `test/zfsbackup`: przypieta wlasnosc
  REV-20260810-092 przechodzi **bez zmian w tescie** — to ona byla dowodem,
  ze pierwsza wersja reguly byla za szeroka.

- Batch A domyka findingi F1–F3 po PR #14: awaryjna instrukcja `--unpair` chroni wspólny blok crona (reinstalacja pozostałych reguł; bezpośrednie usunięcie bloku wyłącznie przy zerze reguł), test publicznego `remove-client` przechodzi przez wieloklientowy config i dowodzi, że własny dataset oraz oba prune'y znikają, a cudza konfiguracja i zadania zostają; osobny dyskryminator dowodzi, że przechwycenie zdalnej polityki źródłowej używa argumentu funkcji, nie przypadkowej zmiennej z zakresu wywołującego. Lokalne dowody: `zfsbackup` 414/0, pozostałe wymagane suity zielone poza istniejącym już na `main` wynikiem `quiescehelper` 117/2 (potwierdzone na czystym `0fec33b`). Live `deploy.sh --check-only` na obu kształtach hosta pozostaje obowiązkiem ręcznym.

- Data odświeżenia: **2026-08-18**. Ostatnia zmiana zachowania: **konto zadań
  jest rozstrzygane przez jednokomendową formę zdalną, a każda odpowiedź jest
  zapisywana.** `zfs-backup.sh --source=HOST:DATASET` wymagał `--local-user=`,
  bo bez niego `add-client` odmawiał — a flaga miała w praktyce jedną sensowną
  wartość, skoro każdy host wdrażany tym produktem i tak kończy z kontem
  `zfsbackup`. Kolejność jest teraz: jawne `--local-user` (z `root` włącznie) →
  `LOCAL_USER` z `server.conf` → konto delegowane, które host **już ma** →
  `zfsbackup`. Rozstrzygnięcie następuje wyłącznie przy ZAKŁADANIU relacji; przy
  wznowieniu konto jest już związane w rekordzie klienta i manifeście, a
  domyślanie założyłoby konto, którego relacja nigdy nie użyje. Trzy dziury
  domknięte razem ze zmianą, nie po niej. **(1)** `deploy.sh` rozpoznaje konto
  hosta skanem katalogów domowych z checkoutem (Faza 8) — to jest to, co czyni
  gołe `bash deploy.sh` poprawnym na całej flocie. Sztywna nazwa tego pytania
  nie zadaje: na hoście z kontem o innej nazwie, na którym nigdy nie puszczono
  `setup-server`, powstałoby DRUGIE konto obok tego, które `deploy.sh`
  utrzymuje, a nowa relacja chodziłaby z przybysza. `rux_detect_local_user`
  pyta tą samą regułą, po WŁAŚCICIELU katalogu domowego, nie po jego nazwie.
  **(2)** Odmowa była też jedyną rzeczą wymuszającą zapisanie decyzji. Bez niej
  decyzja mieszka per relacja w manifeście — zgodna dziś, rozjeżdżająca się w
  dniu, w którym ktoś uruchomi `setup-server` z inną nazwą, bo przy aktywacji
  `server.conf` bije `PEER_SAVED_LOCAL_USER`: blok crona przeniósłby się do
  konta, które nie umie odczytać klucza, na który zadania dalej wskazują.
  `rux_record_local_user` dopisuje rozstrzygnięcie do `server.conf`, podmieniając
  WYŁĄCZNIE linię konta (`DEFAULT_TARGET`/`CRON_CONFIG` przeżywają), niefatalnie
  — fallback z manifestu dalej odpowiada, więc porażka zapisu jest ostrzeżeniem
  o przyszłym rozjeździe, a nie powodem porzucenia wdrożenia w locie. Jawne
  `--local-user` NIE jest zapisywane: to wybór o jednej relacji, a awans na
  domyślną hosta przepiąłby po cichu każdą następną. **(3)**
  `setup-server --local-user=root` zwijał roota do wartości PUSTEJ, na
  uzasadnieniu, że „znaczy to samo co pominięcie flagi, więc można ją zapisać w
  runbooku bez zmiany zachowania". To było prawdą tylko dopóki pustej wartości
  nikt nie czytał jako zaproszenia do wyboru — a punkt (1) właśnie tak ją czyta.
  Administrator, który świadomie napisał `root`, dostawał konto delegowane przy
  pierwszej relacji. Root jest teraz zapisywany dosłownie (`LOCAL_USER=root`) i
  przenosi się na cały łańcuch wdrożenia; pusta wartość zostaje wyłącznie
  delegacji (`--backup-user` nie jest dla roota wołane). Wartość pusta w
  ISTNIEJĄCYM `server.conf` jest odtąd stanem nieustalonym — znaczyła
  jednocześnie „wybrano roota" i „nie decydowano" — więc forma zdalna **odmawia**
  i nazywa obie komendy naprawcze, zamiast zgadywać; odmawia dokładnie tam,
  gdzie odmawiał kod sprzed RUX, więc nic działającego nie przestaje działać.
  Zmierzone: `test/rux` **33/33** (28/0 na bazie), `test/zfsbackup` +3 przypadki
  (`61a/b/c`: root zapisany, żadne konto dla niego nie bootstrapowane, gołe
  `setup-server` dalej nie zapisuje nic). Na żywo NIEDOWIEDZIONE — brak dostępu
  do klastra metropolis w czasie tej zmiany; ścieżka rozstrzygania jest pokryta
  wyłącznie tekstowo, a łańcuch lab3 dowiedziony 2026-08-17/18 szedł tą samą
  ścieżką z flagą wypisaną ręcznie. Poprzednia zmiana zachowania: **wyrenderowane
  artefakty profilu są ZWALNIANE (maintenance, poza REV-120/121).**
  `load_active_profile()` alokowało trzy pliki `mktemp` i nie usuwał ich żaden
  przebieg — trzy pliki na KAŻDE wywołanie ładujące profil, na stałe. Zmierzone
  na pve0 2026-08-14: 2090 wpisów `tmp.*` w `/tmp`, z tego **1824** kopie
  wbudowanego profilu z dwóch dni przebiegów suity (~1800 na jeden pełny
  `test/zfsbackup/run.sh`). Trap na poziomie pliku by tego NIE naprawił —
  zmierzone: bash zeruje trapy w podpowłoce, a zarówno suita, jak i część
  ścieżek wewnętrznych ładuje profil w `( ... )`; trap jest więc uzbrajany w
  chwili ładowania, w tej powłoce, która naprawdę wyrenderowała profil. Sam trap
  też nie wystarcza tam, gdzie jedna powłoka ładuje dwa razy — drugi render
  osierociłby pierwszą trójkę, więc `load_active_profile` zwalnia poprzedni
  zestaw przed realokacją. O uzbrojeniu decyduje **`BASHPID`, nie `trap -p`**:
  zmierzone na bashu 5.1.4 — w podpowłoce `trap -p EXIT` RAPORTUJE łańcuch
  przodka, choć ten trap nie jest tam uzbrojony i tam nie zadziała. Pierwsza
  wersja poprawki pytała `trap -p`, czy EXIT należy do kogoś innego, w każdej
  podpowłoce suity odczytywała jej własny trap rodzica, uznawała że ma się nie
  wtrącać — i nie uzbrajała niczego. **Wyciek przeżył własną poprawkę**; złapała
  to dopiero kontrola pozytywna. Ta sama miara zabrania ŚLEPEGO doklejania:
  doklejenie raportowanej akcji uruchamiałoby akcję przodka — tu
  `rm -rf "$WORK"` — wewnątrz każdej podpowłoki, niszcząc fikstury trwającego
  przebiegu. Zastępowanie BEZWARUNKOWE było jednak błędem w drugą stronę i
  zostało poprawione (PR #15 F2): kasowało trap EXIT powłoki, która ten plik
  ZESOURCE'OWAŁA, a plik jest sourceowalny z założenia i suita go sourceuje.
  Rozstrzyga jeden dodatkowy fakt — `PROFILE_HOST_PID`, zapisany w zasięgu
  pliku. W tej jednej powłoce raport `trap -p` JEST wiarygodny, więc obca akcja
  jest tam DOKLEJANA (najpierw zwolnienie, potem akcja wywołującego, która widzi
  status, z jakim powłoka wychodziła); w każdej innej raport może być
  odziedziczony i bezużyteczny, więc zostaje zastąpienie wraz z opisanym wyżej
  zagrożeniem. Odwracanie ucieczek z `trap -p` to kontekst WZORCA, gdzie
  samotny backslash escapuje zamiast dopasowywać: pierwsza wersja zwijała `'\''`
  do trzech apostrofów, nie dopasowywała niczego i podawała powłoce
  niezbalansowany łańcuch — handler wywołującego padał wtedy na
  „unexpected EOF", czyli gorzej niż strata, której miało to zapobiec. Zwolnienie **weryfikuje** usunięcie zamiast ufać
  statusowi `rm -f` i **wymienia ocalałe ścieżki**, gdy nie może usunąć
  (doktryna REV-119 F1.4); NIE zmienia statusu wyjścia — żadne zdanie, które ten
  program mówi operatorowi, nie staje się nieprawdą przez plik roboczy w
  `$TMPDIR`, a zgłoszenie udanej transakcji jako nieudanej byłoby większym
  kłamstwem. `lib-profile.sh:346` sprawdzony: **nie ma tego kształtu** (zrzut
  schematu usuwany na wszystkich czterech wyjściach, plik nie definiuje
  `die`/`exit`). Zmierzone przed/po na pve0, izolowany klon, `TMPDIR` prywatny,
  **pod trapem EXIT przodka** (czyli w układzie, który pokonał pierwszą wersję
  poprawki): 5 emisji zostawiało **15** plików, po zmianie **0**, przy zdrowej
  kontroli (emisje faktycznie wyemitowały sekcje profilu). Suita `zfsbackup`
  sekcja 60 — **16 asercji, w tym sześć kontroli**: obrona z wyłączonym
  zwolnieniem MUSI zostawić dokładnie 3, profil odrzucony MUSI być odrzucony za
  pole relationship-owned, trap przodka MUSI nadal zadziałać przy własnym
  wyjściu, plik usuwalny MUSI zniknąć po cichu ze statusem 0, a wstrzyknięta
  awaria alokacji MUSI faktycznie paść (bez tego zerowy wynik nic nie dowodzi).
  **PR #15 F1** — uzbrojenie następowało PO trzecim `mktemp`, więc awaria
  alokacji 2 lub 3 kończyła przebieg z już zaalokowanymi plikami i bez trapu,
  który mógłby po nich sięgnąć; zmierzone na `9751f29`: wymuszenie awarii
  drugiej alokacji renderu zostawiało jeden plik. Uzbrojenie idzie teraz PRZED
  pierwszą alokacją — handler pomija puste zmienne, więc nic to nie kosztuje, a
  pokrywa każdą ścieżkę awarii. Trzy nowe dyskryminatory (częściowa alokacja,
  zachowany trap wywołującego, akcja z apostrofem) sprawdzone jako PADAJĄCE na
  `9751f29` i przechodzące tutaj. Zmierzone po scaleniu z `main`:
  `zfsbackup` **430/0**.
  Poprzednia zmiana zachowania: **Batch A — bezpieczna wieloklientowa rozbiórka po PR #14.** Wcześniejszy etap: **czterokomendowy przepływ dwóch serwerów (issue #9) + naprawa świeżego kolektora.** `add-client → deploy.sh --join → seed → activate` jest na `main` (PR #10). Kampania na ŻYWO na parze metropolis (pve1 → pve2, 2026-08-14) dowiodła komend 1–3 end-to-end na prawdziwym ZFS: wsad, prowadzony join z inwentaryzacją rzeczywistych datasetów i nadaniem uprawnień na DOKŁADNIE jeden dataset (proponowany zakres obejmował całą pamięć pve2 z produkcją włącznie i został zawężony przed akceptacją), oraz seed z **realnie przesłanymi 12,1 MB**. Komenda 4 odsłoniła defekt blokujący: `cmd_activate_client` buduje kopię roboczą configu i przy BRAKU configu tworzył ją PUSTĄ, a `ensure_cron_config` zasiewa `[defaults]` tylko gdy pliku nie ma — `mktemp` już go stworzył. Efekt: datasety zapisane na niczym i odmowa `gen-cron.sh: [defaults] must set host_label`, czyli ręczna naprawa CONFIG-u, której issue #9 zabrania. Niewidzialne na każdym kolektorze, który config już ma; widoczne dokładnie przy pierwszym wdrożeniu dwóch serwerów. Zasiewanie jest teraz JEDNĄ funkcją (`write_fresh_config_defaults`) używaną przez obu wywołujących, zamiast literału w jednej gałęzi, o którym druga zapomniała. Po naprawie config się generuje i renderuje pełny podgląd crona (send, prune celu, prune źródła, monitor, digest). Instalacja zatrzymała się na DRUGIEJ, poprawnej bramce: zainstalowany blok zarządzany w crontabie roota na pve1 pochodzi z `/tmp/…/jobs.conf` po dawnej kampanii i już nie istnieje, więc `assert_cron_config_matches_installed` odmówiła — instalacja skasowałaby to, co ten blok opisuje. **Nic nie zmutowano**: crontaby roota i konta na obu hostach zweryfikowane bajt w bajt wobec kopii sprzed przebiegu. Pełny transkrypt czterech komend został domknięty **2026-08-24** na kolektorze pve9 ze źródłem pve2 — czyli dokładnie na kolektorze, którego blok zarządzany nie jest pozostałością po teście, czego ten akapit wymagał. Dowody i werdykt: sekcja „Tor czterech komend — ZAMROŻONY” niżej. Zgłoszone osobno, nie naprawione po cichu: `add-client` bez `--local-user` deklaruje cel jako „delegated to nobody" i generuje zadania rootowe na flocie zmigrowanej na konto delegowane; komunikat końcowy `seed` nadal odsyła do `final-catchup`/`set-endpoint`/`verify-endpoint`/`activate-client`, czyli do sekwencji, którą #9 usuwa; szkic zakresu domyślnie daje `include_parent = no`, co dla liścia nie wybiera niczego (odmawia czysto, ale bezużytecznie). Rozbiórka relacji też została naprawiona, bo kampania na żywo pokazała, że `remove-client` nie umie posprzątać po sobie: rekord klienta trzyma ścieżki CELU (`MANAGED_DATASETS`, `MANAGED_PRUNE_SCOPE`), a scope prune'a ŹRÓDŁA to endpoint (`konto@host:dataset`), więc `remove_managed_sections` nigdy się o nim nie dowiadywała i sekcja przeżywała. Kaskada: następny krok generował cron z niesprzątniętego configu i wstawiał linię z powrotem, po czym `--unpair` odmawiał z powodu linii, którą usuwanie właśnie odtworzyło; a zalecana w komunikacie naprawa była niewykonalna, bo config pozbawiony ostatniej reguły nie daje się zainstalować (`gen-cron` słusznie odmawia renderowania pustki). Usuwanie woła teraz `remove_client_remote_source_prunes` — ten sam helper, którego aktywacja używa do przeniesienia tej sekcji przy zmianie endpointu, więc reguła własności bez zmian (marker, cudze sekcje nietknięte). Komunikat `--unpair` podaje kolejność, która działa: config, potem crontab. **Czwarty defekt, starszy od tej naprawy, odsłonięty przez jej test:** `remove_client_remote_source_prunes` i `capture_client_remote_source_prunes` budowały marker własności wewnątrz jednego `local`, z tej samej zmiennej, która była w nim przypisywana — a bash rozwija wszystkie słowa polecenia zanim wykona którekolwiek przypisanie, więc marker brał wartość z zakresu WYWOŁUJĄCEGO. Działało wyłącznie dlatego, że jedyny wywołujący miał zmienną o tej samej nazwie i wartości; wywołujący z inną usunąłby sekcje cudzego klienta albo zachował cudzą politykę przy re-aktywacji, a pod `set -u` bez zewnętrznej zmiennej funkcja pada — i tak się to ujawniło, przy pierwszym wywołaniu z testu jednostkowego. Obie rozdzielone na dwie instrukcje. Test jest parą: własny zdalny prune znika, cudzy zostaje (usuwający wszystkie zdalne prune'y przeszedłby pierwszą połowę i po cichu skasował retencję źródła innego klienta). Zmierzone: `zfsbackup` 407/0 wobec bazy 406/0 na czystym `main`. Do tego dwie dalsze poprawki z tej samej kampanii: `seed` nazywa teraz DOKŁADNIE jedną następną komendę (`activate NAME`, z `--host=` gdy endpoint produkcyjny różni się od zaseedowanego) zamiast recytować `final-catchup`/`set-endpoint`/`verify-endpoint`/`activate-client`, czyli sekwencję, którą #9 usuwa ze zwykłej ścieżki; a szkic zakresu przestał wpisywać `include_parent = no` liściom — to poprawne dla kontenera i NIE WYBIERA NICZEGO dla liścia, przez co prowadzony join odmawia, a operator musi ręcznie poprawić linijkę na ścieżce, która z definicji nie wymaga ręcznej edycji. Obie asercje pinujące stare brzmienie zostały PRZEPISANE do nowego kontraktu, nie skasowane: podpowiedź po seedzie musi nazywać `activate` ORAZ nie wymieniać żadnego z czterech eksperckich czasowników (sama pierwsza połowa przepuściłaby podpowiedź, która dodaje nową komendę i dalej recytuje stare), a reguła słownictwa („the peer", nigdy „the source") jest pinowana słowami, nie całym zdaniem — regułę wzięto z prawdziwego findingu recenzji i przeredagowałem własny tekst, żeby ją zachować. Zmierzone: gałąź dała 404/2 wobec 406/0 na main, obie porażki moje, po przepisaniu asercji 406/0. Poprzednia zmiana zachowania: **REV-120 runda 2 + REV-121 — zniszczenie nie może poszerzyć zatwierdzonego zbioru, a punkt docelowy nie może być zgadnięty.** Runda 1 mierzyła zbiór tuż przed zniszczeniem i dalej wołała `zfs rollback -r`; pomiar zwęża okno, ale go nie zamyka, bo odczyt i zniszczenie to nadal dwie chwile, a `-r` sam decyduje, co jest nowsze od bazy. Teraz własność niesie KSZTAŁT poleceń: każde wywołanie niszczące to albo `zfs destroy` nazywające zatwierdzone obiekty WPROST (nie tknie niczego innego, cokolwiek by w międzyczasie przyszło), albo **nierekurencyjny** `zfs rollback`, który sam odmawia, gdy istnieje cokolwiek nowszego — ZFS sprawdza to wewnątrz polecenia, nie my przed nim. Zmierzone identycznie na 2.1.9 i 2.2.2: `zfs destroy ds@a,b,c` usuwa wiele snapshotów jednym wywołaniem, składnia z przecinkiem NIE działa dla bookmarków, a nierekurencyjny rollback przy nowszym bookmarku odmawia, wymienia winowajców i nie niszczy niczego — łącznie z danymi żywymi. Cena jest nazwana wprost: zniszczenie zaczyna się teraz PRZED rollbackiem, więc spóźniony obiekt to porażka częściowa (2), a nie czysta odmowa (1). **REV-121:** domyślny punkt docelowy nie jest już ostatnim wierszem listy sortowanej po `creation` — oś zostaje `creation` (to czas powstania danych, czyli sens polityki właściciela), ale gdy maksimum dzieli kilka snapshotów, czasownik ODMAWIA i wymienia kandydatów zamiast wybierać po przypadkowej kolejności. Poprzednia zmiana zachowania: **REV-120 runda 1 —
  zbiór niszczony i test końcowy liczone przez `createtxg` i tożsamość, a
  BOOKMARKI są częścią zbioru strat.** `zfs rollback -r` kasuje również bookmarki
  nowsze od punktu docelowego (zmierzone na pve0: rollback do `@s1` przy
  `#bm1/#bm2/#bm3` zostawił samo `#bm1`), a planer ich w ogóle nie wyliczał —
  więc prymityw poszerzał zatwierdzony zbiór w chwili wykonania. Teraz: baza
  źródła rozwiązywana po GUID-zie **razem z jej `createtxg`**, zbiór blokad
  liczony jako `createtxg > baza` dla snapshotów **i** bookmarków (koniec z
  pozycją w liście sortowanej po `creation`), nieudany odczyt = zbiór
  NIEDOWIEDZIONY (odmowa przed pierwszą mutacją, nie pusta lista), bookmarki
  wypisane w mierzonym zbiorze strat, granica zatwierdzenia rewaliduje je tak
  samo jak snapshoty, a **tuż przed komendą niszczącą zbiór jest mierzony
  ponownie i musi być DOKŁADNIE równy zatwierdzonemu** — inaczej odmowa i nic nie
  zniszczone. Test akceptacyjny nie pyta już „czy ostatni wiersz listy sortowanej
  po `creation` niesie GUID celu" (to nie jest porządek totalny), tylko: snapshot
  o `RESTORE_TARGET_GUID` istnieje na źródle (dokładnie jeden wiersz) i **nic na
  źródle nie jest od niego nowsze** — snapshot ani bookmark, po `createtxg`.
  Poprzednia zmiana zachowania: wycinek WYKONANIA
  ścieżki niszczącej (Faza 7, R-026 po zamknięciu REV-119) — `restore_execute()`
  wykonuje krok, na który poprzednie wycinki tylko się przygotowywały: rollback
  zakotwiczony GUID-em dla każdej strategii + odbiór przyrostowy gdy punkt jest
  przed źródłem, akceptacja przez GUID, rozdzielona semantyka porażki (nic
  zniszczone vs częściowo), ogrodzenie w dół na końcu. Nadal WEWNĘTRZNIE, bez
  publicznej gramatyki (właściciel ją ustala). Dowiedzione end-to-end na żywym
  ZFS (pve0, wszystkie trzy strategie, GUID poza narzędziem). Faza 7 ma na main wycinek 1 (planer read-only), wycinek 2
  (bezpieczne odtworzenie do namespace, staging + promocja przez `zfs rename`),
  pełną mapę planera i **czytany-tylko podgląd domyślnej strategii** pod
  polityką właściciela z 2026-08-12 („najnowszy punkt z powrotem do oryginalnej
  ścieżki", `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`). Podgląd rozróżnia
  pięć werdyktów i nazywa WSZYSTKO, co operacja niszcząca by zniszczyła: nie
  tylko snapshoty źródła nowsze niż wspólna baza, ale też dane zapisane po
  ostatnim snapshocie źródła (`written`), których nie ma w żadnym snapshocie.
  **Werdyktu „nic do zrobienia" już nie ma**: `written=0` odzwierciedla ostatni
  zatwierdzony txg, więc niczego nie dowodzi o stanie bieżącym — podgląd mówi
  „nie rozliczono zmian", nigdy „zmian nie ma".
  Ścieżka niszcząca **istnieje jako funkcja WEWNĘTRZNA**
  (`restore_replace_internal`, nieosiągalna z CLI): rozwiązuje relację, odrzuca
  wszystko, czego nie umie dowieść, **mierzy dokładny zbiór strat na technicznym
  snapshocie przed pytaniem o zgodę**, po zgodzie stawia ogrodzenie zapisu
  (`readonly=on`), sprawdza granicę zatwierdzenia — **a potem WYKONUJE**
  (R-026, wycinek po zamknięciu REV-119). Jeden zakotwiczony GUID-em rollback
  jest prymitywem dla każdej osiągalnej strategii: `rollback`/`discard-live`/
  `unproven` cofają źródło do punktu odtworzenia (blokady i żywe zapisy giną
  jednym atomowym krokiem, techniczne snapshoty tego przebiegu z nimi), a
  `increment` po tym rollbacku dobiera brakującą deltę jednym odbiorem
  przyrostowym. Akceptacja jest przez TOŻSAMOŚĆ, nie przez kod wyjścia i nie
  przez pozycję w liście (REV-120 F2): snapshot o GUID-zie punktu docelowego musi
  być na źródle — dokładnie jeden wiersz — i nic na źródle nie może być od niego
  nowsze, ani snapshot, ani bookmark, licząc po `createtxg`. Inaczej przebieg
  zawiódł. Zatwierdzony zbiór strat obejmuje BOOKMARKI (REV-120 F1) i jest
  mierzony ponownie tuż przed komendą niszczącą; różnica = odmowa, nic nie
  zniszczone. Semantyka porażki jest rozdzielona: rollback jest atomowy, więc jego
  niepowodzenie NIC nie niszczy (i wolno powiedzieć „źródło jak przed
  poleceniem"), a nieudany transfer PO rollbacku zostawia źródło na wspólnej
  bazie i mówi to wprost, nigdy nie udając nietkniętego źródła. Ogrodzenie
  schodzi na końcu; jego nieudane zdjęcie po UDANYM odtworzeniu jest głośne i
  osobne od samego odtworzenia. **Dowód end-to-end na żywym ZFS (pve0,
  zfs-2.1.9, 2026-08-14):** wszystkie trzy strategie — increment (delta realnie
  przeniesiona, dane wróciły), rollback (blokady zniszczone, 57344 B), i
  discard-live (4 MiB zatwierdzonych żywych zapisów odrzuconych) — GUID
  potwierdzony poza narzędziem, ogrodzenie w dół, brak pozostałości.
  **Publicznej gramatyki nadal nie ma i celowo nie powstaje**: właściciel dopiero
  decyduje o selektorze i celu w CLI (R-018/R-019), a publiczną flagę trudniej
  wycofać niż dodać. Stan plików, który ten blok opisuje, jest
  w znaczniku maszynowym powyżej — celowo NIE powtórzony tutaj, bo dwie
  kopie tej samej informacji to dwie rzeczy, które mogą się rozjechać.
  `gen-cron.sh` **v4.30**, `snapsend.sh` **v2.72**, `snapget.sh` **v2.69**,
  `delsnaps.sh` **v1.29**, `check-snap-age.sh` **v2.3**.

  **CO JEST WDROŻONE, A CO NIE — stan na dziś.** To jest jedyne miejsce, gdzie
  ten podział ma być aktualny; szczegóły każdej pozycji leżą w artefaktach
  kanonicznych i NIE są tu powtarzane, bo druga kopia zmiennych szczegółów
  rozjeżdża się dokładnie tak, jak rozjechał się ten blok (REV-20260809-078).

  | rzecz | stan | gdzie leży prawda |
  |---|---|---|
  | Etap 2.1 — jeden sufiks nazwy na PRZEBIEG | **wdrożone** | suita `runsuffix`, dowód na żywo w sekcji 5 |
  | Etap 2.2 — dokładnie JEDNA deklaracja rekursji na wywołanie | **wdrożone** | suita `recursion` |
  | Etap 2.3 — długie opcje `--recursive=atomic\|flat\|no` | **wdrożone** w `snapsend.sh`/`snapget.sh` (+ `--recursive` ≡ `-R` w `delsnaps.sh`/`check-snap-age.sh`) | suita `recursion` |
  | Etap 3 — ZAMROŻENIE SILNIKA | **wdrożone i domknięte** | `docs/project/ENGINE-FREEZE.md`, egzekwowane przez `./test/impact.sh` |
  | Etap 4 — `gen-cron.sh --reconcile` | **wdrożone i domknięte** (REV-071…074) | suita `reconcile`, `docs/testing/RECONCILE-*.md` |
  | Etap 5 — GRANICA profilu | **wdrożona jako kod PRODUKCYJNY** `lib-profile.sh` | REV-073/076/077, suita `profiles` |
  | Etap 5 — RENDERER profilu (`profile_render_templates`/`profile_render_fragment`, namespace `profile__<nazwa>__<szablon>`) | **wdrożony** w `lib-profile.sh`, suita `profiles` 55/55; nazwa profilu i szablonu nie może nieść `__` (REV-081 F1: kodowanie nie było różnowartościowe) | plasterek B1, krok 1 |
  | Etap 5 — RUNTIME profilu (`zfs-backup.sh` czyta profil zamiast zaszytych szablonów) | **wdrożony** (B1 krok 2): `ensure_cron_config` i `emit_client_sections` czytają wyrenderowany profil, pre-GFS **odmawia** zamiast konwertować; suita `zfsbackup` 333/333, kontrola negatywna 14 pada | `docs/design/slice-b1-plan.md` |
  | jednokierunkowe przekazanie profilu (PROFIL → generuj RAZ → CONFIG v4 → prawda wykonawcza) — re-aktywacja i przełączenie endpointu NIE regenerują polityki | **wdrożone; REV-089/090/091 ZAMKNIĘTE; Gate 3 DOMKNIĘTY przez recenzenta 2026-08-10** (Faza 3 planu prac, `docs/discussions/GATE3-PHASE35-REVIEWER-RESOLUTION-2026-08-10.md`): pierwsza aktywacja generuje z profilu jak dotąd; re-aktywacja bierze ZAINSTALOWANĄ sekcję za bazę i odświeża w miejscu wyłącznie dwa pola topologiczne (`src`, `flags`), zostawiając politykę, `pair_label`, `notify` i ręczne dopiski nietknięte; sekcje `[prune:]` nie niosą ŻADNEGO pola topologicznego, więc własna sekcja prune nie jest ruszana w ogóle (oba kształty: drabina GFS w trybie backup i per-dataset w trybie sync); `migrate-profile` przekazuje flagę pierwszej aktywacji jawnie, bo regeneracja z profilu jest całym sensem tej komendy | REV-20260809-089 + REV-20260810-090, suita `zfsbackup` sekcje 49/50 (339/339), kontrole negatywne wobec `8d0dc243…` → 328/333 i wobec `c5f04ab0…` → 335/339 |
  | zwykła re-aktywacja NIE wymaga profilu i niczego z niego nie dokleja | **wdrożone, ZAMKNIĘTE** (REV-090, dwa P1): profil jest teraz zależnością LENIWĄ, bramkowaną na granicy, która naprawdę coś generuje — `client_section_plan()` liczy plan wyłącznie z zainstalowanego configu i rekordu klienta (żaden profil nie jest czytany, żeby odpowiedzieć „czy profil jest potrzebny"), a `ensure_cron_config()` dostała parametr `needs_profile` (domyślnie 1), pod który schowano `load_active_profile` ORAZ całą pętlę doklejania szablonów. Skutek: relacja utworzona z profilu `P` daje się re-aktywować po tym, jak `P` zniknął, został przemianowany albo przestał się walidować; a szablon świadomie usunięty przez operatora nie wraca przy odświeżeniu endpointu | REV-20260810-090 (ZAMKNIĘTY) + REV-20260810-091, suity `zfsbackup` sekcje 50/51 (13 asercji przez PRAWDZIWY `cmd_activate_client()`) |
  | zwykła re-aktywacja niczego nie tworzy, nie naprawia, nie normalizuje ani nie migruje | **wdrożone, ZAMKNIĘTE** (REV-091, dwa P1): po REV-090 `ensure_cron_config()` NADAL robiła dwie rzeczy bezwarunkowo — doklejała ogólnokonfiguracyjne progi `[excluded:]` (F1) i odmawiała na configu pre-GFS (F2) — więc `needs_profile=0` wcale nie znaczyło „tylko topologia". Oba schowane pod tę samą bramkę. Sama DETEKCJA pre-GFS dalej biegnie bezwarunkowo (`PROFILE_GFS` czytają dalej kształt prune i podsumowanie aktywacji), warunkowa jest wyłącznie ODMOWA — i nadal pada wszędzie tam, gdzie polityka naprawdę jest generowana na host legacy. Skutek: host pre-GFS można odświeżyć endpointowo bez wymuszania `migrate-profile`, a próg `[excluded:]` usunięty świadomie przez operatora nie wraca | REV-20260810-091 (ZAMKNIĘTY), suita `zfsbackup` sekcja 51 (7 asercji) |
  | dodanie NOWEJ relacji nie zmienia polityki relacji już zainstalowanych | **wdrożone; REV-092 ZAMKNIĘTY, Gate 2 DOMKNIĘTY przez recenzenta 2026-08-10** (był ponownie otwarty): `[excluded:]` NIE jest sekcją niczyją — `gen-cron.sh` skleja wszystkie w jeden ogólnokonfiguracyjny `PROTECT_FLAGS` i dokleja go do KAŻDEJ generowanej linii prune w pliku. Doklejenie brakującego progu przy dodawaniu nowej relacji przepisywało więc realne polecenie prune relacji, które były tam pierwsze. Nowe `config_has_relationship_policy()` + czwarty parametr `global_policy_mode` (`auto`/`always`): świeży CONFIG dostaje domyślne progi, jawna migracja (`migrate-profile`) może je położyć celowo w podglądanej transakcji, a addytywny CREATE do zapełnionego CONFIG-u dziedziczy stan `[excluded:]` dokładnie taki, jaki jest, i niczego nie naprawia — tylko ostrzega, wymieniając brakujące progi | REV-20260810-092, suita `zfsbackup` sekcja 52 (6 asercji na RENDEROWANEJ linii `delsnaps.sh`, nie na tekście configu) |
  | Faza 3.5 — bezprefiksowy create/pasywny `-e`/jednoseriowa drabina GFS w native CONFIG | **wdrożone przez implementera, czeka na recenzenta**: nowa `resolve_field_or_omit()` (owija istniejący rozdzielacz stanów `resolve_field()`: nigdzie-nierozwiązane vs rozwiązane-ale-puste) zastąpiła `require_field` dla `prefix` i `gfs_pattern` — pominięcie pola w całym łańcuchu dziedziczenia jest teraz świadomym „bez prefiksu"/„bez wzorca GFS", obecne-ale-puste dalej odmawia bez zmian (`c90f6d1`). `pattern` NIE został ruszony. Silniki (`snapsend.sh`/`snapget.sh`/`delsnaps.sh`) już wcześniej akceptowały pustą wartość identycznie jak brak flagi — zweryfikowane czytaniem kodu, nie zmienione | `docs/discussions/PHASE35-IMPLEMENTATION-CLAUDE-2026-08-10.md`; suita `gencron` (`test/run.sh`) 67/67, kontrola negatywna wobec `8693b4e3…` → 63/67 |
  | Etap 5 — wiązanie PER-ŹRÓDŁO (jedna relacja, różne profile dla różnych źródeł) | **NIEwdrożone** — brak kompozytora; namespace jest gotowy, żeby to umożliwić | `docs/discussions/PER-SOURCE-PROFILE-SCENARIOS-2026-08-09*.md` |
  | domyślny backup ogranicza retencję ŹRÓDŁA (nie zostawia snapshotów źródła bez ograniczeń) | **WDROŻONE, IMPLEMENTED→recenzent (REV-102)**: krok 2 (local PUSH `cmd_local_backup`) wdrożony — osobna `[prune:<root>]` z tej samej drabiny, non-recursive, tylko `automated_`; grant-guard `assert_source_prune_grant()` (fail-closed na braku `destroy`/błędzie ssh, bez poszerzania) **wylądował + test** (sekcja 55). Rozdział SOURCE/TARGET jest **profile-agnostyczny** (REV-106 IMPLEMENTED): rodzina SOURCE wyprowadzana z szablonów RZECZYWIŚCIE referowanych przez `use_template` profilu (nie z konwencji `keep_*`), fail-closed na braku; jeden współdzielony helper reużywalny przez remote-PULL. Krok 4 (local PUSH) **dowiedziony na żywym ZFS 2026-08-11** (pve1 192.168.28.9, throwaway lab): `delsnaps.sh -G` bez `-R` skasował `automated_hourly_a/b` źródła, zostawił `_c` (survivor GFS), `manual_keepme` (wzorzec) i `child@automated_hourly_child1` (non-recursive) — pełny transkrypt w design doc. Krok 3 (remote PULL) **WDROŻONY na main** (merge `d8febbd`, REV-102 IMPLEMENTED→recenzent): `emit_client_sections` emituje per-źródło zdalny `[prune:account@host:ds]` (niezależna rodzina `__src_keep_*`, non-recursive, `ssh_flags` z transportu pull minus `-b`, szablony źródła bez `monitor_*`), grant-check fail-closed w przepływie (activate + migrate). **Dowiedziony na żywo 2026-08-11**: kolektor pve1 uruchomił emitowany prune przez SSH na źródło pve2, skasował `automated_hourly_a/b`, zostawił `_c`+`manual_keepme`+dziecko. **REV-107 (P1) naprawiony**: re-aktywacja PRZENOSI tylko topologię (scope+ssh_flags) i ZACHOWUJE zainstalowaną politykę źródła (edycja retencji admina przeżywa zmianę endpointu — `capture_client_remote_source_prunes`); podział topologia-vs-polityka jak REV-089, NIE regeneracja. **Krok 5 (migracja/audyt) WDROŻONY na main; F3/F4/F5 naprawione** (recenzent odrzucił pierwsze podejście na „migration false-green"): `zfs-backup.sh audit-source-retention` — domyślnie TYLKO-DO-ODCZYTU; **F3**: „ograniczona" liczona z EFEKTYWNEJ retencji (config renderowany przez PRAWDZIWY gen-cron; źródło bounded ⟺ render emituje `delsnaps` dla dokładnego scope — `source_scope_is_bounded`), nie z obecności nagłówka `[prune:]`; scope źródła brany z zainstalowanego `[dataset:]` `src` (CONFIG=prawda). `--apply`: **F4**: dopisuje TYLKO brakujące source-prune przez wąski `emit_missing_source_prune` (NIGDY `emit_client_sections`, więc bez odświeżania topologii `[dataset:]`); przy rozjeździe endpointu klient-vs-CONFIG ODMAWIA (bez oportunistycznej naprawy). **F5**: transakcja `--apply` (workfile→grant→gen-cron→podgląd→potwierdzenie→instalacja→read-back) testowana end-to-end. **F4/F5 ZAAKCEPTOWANE przez recenzenta (`8cb28f3`)**. **F3 residual naprawiony (`d747b35`)**: `source_scope_is_bounded` łapało JAKĄKOLWIEK linię delsnaps ze scope — w tym `prune-bookmarks` (`delsnaps -B`, nie kasuje snapshotów) i prune innego prefiksu; teraz dyskryminuje semantykę: wyklucza `-B`, pattern MUSI pokrywać zarządzany prefiks źródła (`managed_source_prefix_for_scope` czyta `snapget -m` z renderu, fallback `automated_hourly_`), finite retention. Sekcja 57 (8 asercji: F3 missing/header-no-render/bookmark-only/unrelated-prefix/managed-bounded, F5 refusal, F4 mismatch-refuse, F4 success-topologia-bit-w-bit). **REV-108 (osobny guard własności) IMPLEMENTED→recenzent**: audyt NIE przejmuje retencji źródła pasywnej relacji `-e` (konsumuje cudze snapshoty) — czyta `-e` z zainstalowanych `[dataset:] flags` (`installed_dataset_is_passive`), raportuje osobno „pasywne, poza własnością", nie wchodzi do MISS_SRC, `--apply` zostawia bit-w-bit bez żądania grantu `destroy`; guard przed testem F3. Sekcja 58 (3 asercje: pasywne poza własnością/`--apply` bez grantu/kontrola bez `-e`→flagowane). **REV-110 (F3 residual #2) IMPLEMENTED→recenzent**: `managed_source_prefix_for_scope` używało substring-matcha → sąsiednie scope'y (`rpool/data` vs `rpool/data2`) krzyżowo asocjowały prefiks; teraz exact quoted-token match (jak `source_scope_is_bounded`). Sekcja 59 (2 asercje: exact asocjacja mimo kolidującego sąsiada pierwszego + evidence #5 prune sąsiada nie czyni relacji bezpieczną). **REV-109 (granularność testów) IMPLEMENTED→recenzent**: `test/zfsbackup/run.sh --section retention` uruchamia TYLKO grupę audytu retencji (sekcje 57-59, self-contained własny profil RP56), pomijając 1-56/92 jednym guardem — L0 13/13 w ~1m12s vs ~7min full; no-arg = pełny suite (391/391) z równoważnym pokryciem; cost audit w `docs/discussions/TEST-SUITE-COST-AUDIT-2026-08-11.md`; polityka L0/L1/L2 w mocy. **Ostatni blokujący dowód (ciągłość po utracie wspólnej bazy) DOSTARCZONY 2026-08-12 — kampania na żywym ZFS, BEZ zmiany kodu produkcyjnego.** pve1↔pve2 metropolis, konto delegowane `zfsbackup`, throwaway datasety, oba silniki. Zmierzone: (A) inkrement po prune źródła gdy wspólna baza zostaje; (A4) realny fallback na bookmark gdy zwykły wspólny snapshot zniknie; (A6) konto bez grantu `bookmark` — transfer rc=0 + ostrzeżenie „non-fatal", ubezpieczenia po cichu NIE MA; (A5/B4) brak wspólnego snapshota I brak bookmarka → **jawna odmowa, exit 1, komunikat na stderr** (trafia do maila cron-wrappera), historia CELU nietknięta; (B3) relacja `-r` nie ma i nie może mieć bookmarka, `-R` (B5) ma po jednym na dataset; (C4) lokalny PUSH — `zfs recv -F` sam odmawia nadpisania celu ze snapshotami („destination has snapshots"), exit 1, historia CELU nietknięta; (A7) reklamowane `-f` faktycznie odbudowuje cel i głośno zapowiada zniszczenie. Reguła decyzyjna: ani „allow+warning" ani nowy hard-refuse nie są potrzebne — silnik już odmawia jawnie i nie degraduje ochrony po cichu. Konsekwencja operacyjna nazwana wprost w response: po utracie bazy relacja STAJE (nie leci po cichu) do interwencji człowieka. L0 `--section retention` 13/13. **REV-102 ZAMKNIĘTY przez recenzenta** na `b9fcd40` (2026-08-12 12:00), zamknięcie odblokowane po naprawie nagłówków maszynowych. **REV-20260812-111 (P1, otwarty na Claude) wynikł z tej kampanii** — nie jest to defekt bezpieczeństwa REV-102, tylko odporności operacyjnej: pakiet nie może aktywować relacji, której ciągłość jest z góry bez ubezpieczenia. **Część A WDROŻONA na main (`5e28f5f`)**: `assert_source_prune_grant()` wymaga teraz `bookmark` obok `destroy`, odczytane z TEGO SAMEGO `zfs allow` po przypiętym SSH (zero dodatkowych round-tripów), fail-closed, bez poszerzania — `deploy.sh --commit-scope` już nadaje `bookmark` ([deploy.sh:4543](../deploy.sh)), więc poprawnie sparowany host tego nie dotknie. Testy: para dyskryminująca `tank/ok` vs `tank/nobookmark` różniąca się WYŁĄCZNIE tym uprawnieniem, jeden-wśród-wielu, treść odmowy. Suity: `zfsbackup` **395/395**, `localbackup` **42/42** (zmierzone dwukrotnie — lokalnie i na pve1). **Część B WDROŻONA na main (`58c1cfe`)**: `assert_no_atomic_with_source_retention()` odmawia, gdy relacja mająca dostać zarządzaną retencję źródła deklaruje `recursive = atomic`. Czyta KANDYDATA (workfile przed instalacją), nie to co wygenerował bieżący przebieg — bo warstwa wysokopoziomowa nigdy nie emituje `atomic` (wszystkie generowane `[dataset:]` mają `recursive = no`; legacy `-r` w `flags` to twardy `die` w `gen-cron.sh:692`), więc niebezpieczna wartość może przyjść wyłącznie z ręcznej edycji CONFIG-u. Bramka stoi PRZED grant-checkiem na wszystkich trzech ścieżkach instalujących retencję źródła (activate-client, migrate-profile, `--apply`) — odczyt pliku jest tańszy niż round-trip ssh na źródło. **Świadomie BEZ podmiany na `flat` (-R)**, mimo że `-R` ma bookmarki per-dataset: to inny tryb transferu (inna semantyka kolejności i awarii), a ciche przepisanie ręcznej decyzji admina po to, żeby przejść własny check bezpieczeństwa, to dokładnie ta „pomocna naprawa", którą projekt odrzuca gdzie indziej. Odmowa nazywa konflikt, obie drogi wyjścia i to, że nic nie zmieniono. Kontrola dyskryminująca w testach: **`recursive = flat` MUSI przejść** — guard odrzucający „jakąkolwiek rekursję" wyglądałby poprawnie przy atomic i byłby błędny. Suity na `58c1cfe` (pve1): `zfsbackup` **401/401**, `localbackup` **42/42**. Kompatybilność sprawdzona na żywo, read-only, oba hosty metropolis: JEDYNY dataset, na którym `zfsbackup` nie ma `bookmark`, to labowy `hdd/rev102nobm` celowo tak zdelegowany — czyli naraz dowód, że żadna produkcyjna relacja nie zostanie odrzucona, i kontrola pozytywna, że detektor w ogóle działa. Response: [REV-20260812-111.md](internal/reviews/responses/REV-20260812-111.md), REV **ZAMKNIĘTY przez recenzenta** 2026-08-12 15:01 (APPROVED na `58c1cfe`, closure `f6c1549`). Ryzyko nazwane wprost: CONFIG ręcznie zmieniony na `atomic` PO zainstalowaniu retencji nie jest ponownie sprawdzany, bo nic nie rewaliduje zainstalowanego CONFIG-u cyklicznie — to własność projektu sprzed tej zmiany, nie regresja. | `docs/discussions/PHASE5-SOURCE-RETENTION-DESIGN-2026-08-11.md`; suity `localbackup` 42/42, `zfsbackup` 391/391 |
  | preflight nakładania pokrycia (create-only preset odmawia relacji, której ścieżka jest rodzicem/dzieckiem/dokładnym trafieniem cudzego pokrycia; fail-closed też na rekordzie nie do odczytu/parsowania; sprawdzane PRZED prawdziwym `seed`, nie tylko przy `activate-client`) | **wdrożony i dowiedziony na żywo (2026-08-09)**, kod: `coverage_conflicts`/`assert_no_coverage_overlap` w `zfs-backup.sh`, wywoływany z `cmd_seed()` i `emit_client_sections()`; suita `zfsbackup` sekcje 45/46/47/48 | REV-20260809-083/084/085/086; dowód na żywo na metropolis pve1/pve2: druga, różnie nazwana relacja (bez własnego `add-client`, dziedzicząca manifest peera pierwszej) trafia realnie do `cmd_seed()` i zostaje odrzucona z dokładnym nazwaniem konfliktu, PRZED jakąkolwiek mutacją; CONFIG/crontab/poddrzewo ZFS bit-w-bit bez zmian — pełny transkrypt w odpowiedzi REV-086 |
  | jednohostowa orkiestracja wysokopoziomowa (`--target`/`--source`, add-local) | **WDROŻONE i ZAMKNIĘTE (KROK 5, 2026-08-25)** — pełna ścieżka odkrywania: brak `--source` proponuje datasety z inwentarza ZFS (układ hierarchiczny nie jest zgadywany), brak `--target` proponuje cel, a żadna z propozycji nie instaluje się pod `--yes`; powtórzenie tego samego polecenia jest no-opem, kolejne źródło dołącza do celu zarządzanego przez to samo narzędzie, a obca sekcja albo inny cel nadal odmawiają. Dowód akceptacyjny na czystym hoście, oba warianty (root i konto delegowane), bez ręcznej edycji CONFIG-u, grantów i crontaba | PR #159, #160 |
  | restore | **CZĘŚCIOWO wdrożone; ścieżka BEZPIECZNA LIVE-PROVEN 2026-08-15 (md5+GUID, wdrożony kod)** (Faza 7): planer read-only, bezpieczne odtworzenie do wyprowadzonego namespace, mapa planera i podgląd domyślnej strategii odtworzenia. Ścieżka NISZCZĄCA istnieje **wewnętrznie i WYKONUJE** — odmawia wszystkiego czego nie dowiedzie, mierzy, potwierdza, ogradza, sprawdza granicę i odtwarza (rollback zakotwiczony GUID-em dla każdej strategii, plus przyrost gdy punkt jest przed źródłem), akceptacja przez TOŻSAMOŚĆ (snapshot o GUID-zie celu istnieje i NIC na źródle nie jest od niego nowsze — snapshot ani bookmark, po `createtxg`), a zatwierdzany zbiór strat obejmuje BOOKMARKI i jest rewalidowany tuż przed komendą niszczącą (REV-120); dowiedzione end-to-end na żywym ZFS (pve0). Publicznej gramatyki nadal nie ma (właściciel ją ustala), więc funkcja jest nieosiągalna z CLI | wiersz suity `restore` niżej; `OWNER-RECOVERY-DEFAULT-POLICY-2026-08-12.md`, `OWNER-RESTORE-CLI-GRAMMAR-2026-08-13.md` |

  Najważniejsze dziś rozróżnienie — jedno zdanie, nie powtarzane niżej
  (REV-20260809-082 F3): **`zfs-backup.sh` czyta profil przy generowaniu
  configu, ale nikt profilu nie WYBIERA.** Jest jeden wbudowany preset i
  używają go wyłącznie nowe enrolmenty; żaden host we flocie nie został na
  niego przeniesiony i decyzja właściciela z 2026-08-09 mówi, że profil
  generuje kandydata JEDEN RAZ, po czym prawdą wykonawczą jest CONFIG v4, a
  nie profil.

  Stan wątków recenzji jest GENEROWANY i nie jest tu przepisywany:
  `docs/internal/reviews/REVIEW_LEDGER.md` oraz `docs/project/OPEN-THREADS.md`
  (`./test/reviewctl.sh --generate`). Dostawy bez recenzji:
  `docs/project/DELIVERIES.md`.

- **Stan poprzedni, 2026-08-07 (zachowany jako historia, NIE jako opis
  dzisiejszego drzewa).** Stan plików, który ten blok opisywał, jest
  w znaczniku maszynowym powyżej — celowo NIE powtórzony tutaj, bo dwie
  kopie tej samej informacji to dwie rzeczy, które mogą się rozjechać.
  `gen-cron.sh` **v4.30**, `check-snap-age.sh` **v2.2**.

  **Etap 0 WYKONANY na pve0**: sześć datasetów gości objętych kopią
  (VM 104 `debian` — **działająca, wcześniej bez żadnej kopii** — VM 103,
  VM 107 ×3, CT 105). Granty `zfs allow` nadane per dataset, pierwsze
  snapshoty wykonane, wszystkie trzy linie monitora `rc=0`. Blok crontaba
  29 → 33 linie, identyczny z renderem configu.

  **`gen-cron.sh --install` naprawione dla konta delegowanego**: blokada
  instalacyjna przeniesiona z `/var/run` (tylko root) do współdzielonego
  katalogu projektu, z tą samą dyscypliną co `lib-cron.sh`. Wcześniej konto
  będące właścicielem zarządzanego bloku **nie mogło go zainstalować**, a
  komunikat błędu twierdził nieprawdziwie, że trwa inny `--install`.

  **Pliki blokad naprawiane i audytowane, nie tylko ich katalog.** `deploy.sh`
  nadawał katalogowi blokad `2775 root:zfsalert` i na tym audyt się kończył —
  ale katalog setgid nadaje plikowi tylko **grupę**, nie **tryb**. Trzy z
  czterech hostów miały blokadę `0644 root`, przez którą konto delegowane nie
  mogło w ogóle zapisać własnego crontaba, podczas gdy `--check-only`
  raportował katalog jako poprawny. Naprawione w `cron_lock_files_repair()` i
  `cron_lock_files_audit()`; wszystkie cztery hosty doprowadzone do stanu
  poprawnego.

  Audyt sprawdza **oba** warunki: wspólna grupa **i** zapis grupy (REV-062).
  Wcześniej pilnował tylko trybu, więc plik `0664` należący do grupy `root`
  przechodził, choć konto delegowane i tak nie mogło go otworzyć — audyt nie
  weryfikował tego, co gwarantuje jego własna naprawa.

  **Świeżość tego dokumentu jest teraz sprawdzana maszynowo** przez
  `./test/impact.sh --verify` (znacznik powyżej). Obowiązek `project-status`
  przestał być prośbą.

  **Model rekurencji: ZAMKNIĘTY I WDROŻONY.** `[dataset:]` przyjmuje pole
  `recursive = no | flat | atomic`, które steruje **wszystkimi trzema** liniami
  generowanymi przez sekcję — transferem, prune'em inline i monitorem. `-r`/`-R`
  we `flags` jest błędem krytycznym, sprawdzanym równoważnie z `getopts` (formy
  sklejone `-Rv`, `-rZ` odrzucane; argument opcji, np. `-m R-daily_`, nie jest
  mylony z flagą). Silnika nie ruszano — zmiana dotyczy generatora, walidatora
  i `cron2conf.sh`.

  **Migracja floty WYKONANA 2026-08-07 14:42** przez
  `gen-cron.sh --migrate-recursion` na 192.168.11.11 (jedyny host, który jej
  wymagał). Crontab md5 **bez zmian**, właściciel i prawa zachowane, kopia
  rollback zostawiona, render identyczny z zainstalowanym blokiem.
  **Żaden zarządzany config we flocie nie niesie już `-r`/`-R` we `flags`** —
  zweryfikowane detektorem na wszystkich czterech hostach.

  **Monitor: wiek z `creation` datasetu** (REV-056, **ZAMKNIĘTA przez
  recenzenta**). Gdy nic nie pasuje do wzorca, wiek liczony jest z daty
  utworzenia datasetu i przechodzi przez tę samą drabinkę progów — świeża
  maszyna czyta się OK, trzydniowa bez kopii nadal CRITICAL. Nieodczytany
  znacznik czasu to UNKNOWN, nigdy zmyślony wiek (naprawione po obu stronach,
  łącznie z istniejącą wcześniej ścieżką pasującego snapshotu).

  **Kontrola migracji niezależna od UID-u** (REV-058, **ZAMKNIĘTA przez
  recenzenta**, `ebe951c`). Configi są `root:root 0644` w `/etc`, więc migrację
  zapisuje root — a zarządzany blok należy do konta delegowanego. Kontrola
  szuka teraz bloku po jego własnej linii `# Source:` u wszystkich użytkowników
  i **odmawia przed zapisem** przy każdej niepewności: nieczytelny crontab,
  nieczytelna lista użytkowników, dwa pasujące bloki.

  **Nowy dokument `docs/discussions/ENGINE-FINALIZATION-PROFILES-RESTORE-2026-08-07.md`
  i moja odpowiedź `ENGINE-PROFILES-RESTORE-CLAUDE-ANSWERS-2026-08-07.md` to
  DYSKUSJA PROJEKTOWA, nie stan wdrożony.** **Na dzień 2026-08-07** nic z długich
  opcji rekursji, profili ani restore nie było zaimplementowane. Zdanie jest
  prawdziwe o tamtym dniu i o żadnym późniejszym: długie opcje rekursji weszły
  w Etapie 2.3, granica profilu jest kodem produkcyjnym od REV-076/077, restore
  nadal nie istnieje. Aktualny podział — w bloku bieżącym na górze pliku.

  Otwarte, oddzielone od pracy już wykonanej: patrz sekcja 6 oraz
  `docs/project/OPEN-THREADS.md`. W skrócie — u recenzenta werdykt dla REV-057;
  u właściciela decyzje o
  `docs/OPS_MONITORING.md`, PR #4 oraz sposobie ogłaszania się równoległych
  sesji.

- **Stan poprzedni, 2026-08-07 (nieaktualny, zachowany dla historii):** commit
  `121892f`, `gen-cron.sh` v4.27 — model rekurencji przebudowany, ale migracja
  floty jeszcze **niewykonana**, a wdrożony na 192.168.11.11 generator odmawiał
  obsługi własnego configu tego hosta. Oba te zdania przestały być prawdziwe
  2026-08-07 o 14:42.
- Poprzednie odświeżenie, 2026-08-07: **pakiet hard-disable ZAMKNIĘTY przez
  recenzenta** (`REV-20260807-052`, APPROVED — zero otwartych znalezisk; zamknięte
  także REV-049, REV-050 i REV-051). Zbudowany i zweryfikowany na żywo
  2026-08-06 wieczorem: **hard-disable ZBUDOWANY
  I ZWERYFIKOWANY NA ŻYWO** (ADR-0012 `DISABLED`). Bramka `zfs-pair-gate.sh` po
  stronie peera, wpinana automatycznie przy `--join` (wymuszone polecenie w
  `authorized_keys` + własny katalog stanu relacji), orkiestracja
  `disable-client`/`enable-client` w kolejności z ADR (pauza lokalna → peer →
  odczyt zwrotny; enable odwrotnie), oraz `check-snap-age`/monitor bez zmian.
  **Właściwość, dla której to powstało, potwierdzona na żywo:** przy blokadzie
  ręcznie napisany `snapget` BEZ żadnej etykiety `-L` jest odrzucany przez
  peera (`PAIR_DISABLED`) — czego pauza logiczna z definicji nie potrafi.
  Kampania na dwóch prawdziwych relacjach (druga na osobnym LXC) znalazła i
  naprawiła trzy defekty: wyciek logu na stderr wywołującego (`6914c11`),
  wybór logu po obecności zamiast po dostarczeniu (`0d6dbf8`, REV-047),
  własność `authorized_keys` przy podmianie atomowej — lockout całego konta
  (`0058834` + fail-closed `209231c`, REV-049), plus własność katalogu stanu
  (`8f6f8c2`) i mylącą diagnostykę `verify-endpoint` (`8de89e1`).
  Suity: `pairgate` 45/45 (nowa), `zfsbackup` 291/291, reszta grafu zielona.
  Pełny materiał dowodowy: `docs/project/HARD-DISABLE-CAMPAIGN-PLAN.md`.
  OGRANICZENIE ZAPISANE WPROST: klucz relacji może sam zdjąć swoją blokadę
  (decyzja właściciela), więc `DISABLED` zatrzymuje automat, pomyłkę i ręczne
  polecenie, ale nie świadomego posiadacza klucza; każde zdjęcie trafia do
  logu na peerze.
- Data odświeżenia: **2026-08-06** (dodatkowo: **REV-20260804-045 w toku** —
  właściciel potwierdził zakres „tylko pauza logiczna"; plasterki 1-3 na main:
  `pause-client`/`resume-client` + stan w `/var/lib/zfs-snapshot-all/
  relationships/`, bramka `-L` w snapget/snapsend (SKIPPED przed jakąkolwiek
  pracą, status statystyk `skipped_paused`), pole `pair_label` w gen-cron
  (linia transferu + monitory; prune celowo NIEbramkowany — retencja chodzi
  dalej podczas pauzy) i `check-snap-age -L` (pauza = OK z nazwanym powodem,
  nie strona). JAWNE OGRANICZENIE, część kontraktu: ręczne uruchomienie BEZ
  `-L` nie jest blokowane — pauza logiczna to przełącznik orkiestracji, nie
  granica bezpieczeństwa; twardy disable po stronie peera pozostaje
  niezaimplementowany. **Plasterek 4 wykonany na żywo tego samego dnia:**
  rollout floty okazał się no-opem (wszyscy klienci na jedynym kolektorze
  byli `state=removed`; `pair_label` wejdzie naturalnie przy najbliższym
  prawdziwym `activate-client`), a test izolacji przeszedł na dwóch
  zbudowanych do tego relacjach (pa ← prawdziwy pve2, pb ← throwaway LXC
  wzorem Gate G): dokładne wygenerowane linie crona uruchamiane jako konto —
  pauza pa = SKIPPED/`skipped_paused`/zero snapshotów u źródła, pb
  transferuje normalnie, monitor pa = OK-paused (nie strona, nie cisza),
  sumy config+crontab bajt w bajt przez cały cykl, resume = przyrostowe
  nadrobienie. Kampania znalazła i naprawiła DWA realne błędy: zamek
  lib-cron tworzony z umaską roota blokował konto na zawsze (`62e190d`,
  test/cron sekcja V, 124/124) i alias known_hosts chown-owany po
  `LOCAL_USER` zamiast po ścieżce konta (`39e4ed2`, test/zfsbackup 41b,
  279/279). Pełny dowód: `docs/internal/reviews/responses/REV-20260804-045.md`.
  Znane ograniczenie projektowe potwierdzone na żywo: JEDNA relacja na parę
  hostów (drugi klient na ten sam adres peera splata manifesty po obu
  stronach; strażnik U11 poprawnie odmówił). Po
  odpowiedzi na **REV-20260806-046** —
  werdykt o dostarczalności alertów orzekał zdrowie z braku dowodów; F1/F2/F3
  IMPLEMENTED, nowa suita `alertmail`, szczegóły niżej; wcześniej: po REV-034
  w całości, po REV-033
  plasterkach 1-10 (WSZYSTKIE dziesięć z pierwotnego planu) + korekcie U9 +
  łatki T3/U2/T5 z `ENROLMENT-AGREED-2026-08-02.md`, po REV-035, po REV-036
  w całości + wszystkie follow-upy, po ad hoc `--pause`/`--resume` poza
  kolejką recenzji (przeróbka na tryb blokowy), po REV-20260804-037 w
  całości, REV-20260804-038 w całości, REV-20260804-039 w całości (F1
  disputed-with-evidence, F2/F3/F4 zamknięte), REV-20260804-040 w całości
  (UID-binding), REV-20260804-041 w całości (transakcja last-client),
  po REV-20260804-042 Gate G i Gate I zamknięte NA ŻYWO (owner wybrał
  budowę labu zamiast NEEDS-DISCUSSION), po REV-20260804-043 — P1
  korekta znaleziona przez recenzenta PRZED wdrożeniem, naprawiona i
  ponownie zweryfikowana na żywo tego samego dnia, i po
  **REV-20260804-044 — werdykt końcowy: ACCEPTED**, cała kampania Gates
  A-J zamknięta bez odpowiedzi implementera)
- Zweryfikowano przeciw: **commit niosący ten dokument** — dokument nie może
  podać własnego SHA, więc ta linia jest konwencją, nie niedopatrzeniem
- Ostatni stan floty potwierdzony na żywo: **2026-08-06 ~16:30**, CZTERY
  osiągalne hosty (metropolis pve1/pve2, 11.x pve0/pve1) na `d859af5`,
  `audit clean` na każdym, kolejki poczty puste. Po drodze audyt złapał na
  11.11 pve1 **brak `/var/lib/zfs-snapshot-all/locks`** — ta sama usterka,
  którą 2026-08-04 znalazł na pve0 (patrz niżej), naprawiona tak samo:
  pełny `bash deploy.sh` (narzędzie-właściciel katalogu, nie ręczny
  `mkdir`), katalog powstał `2775 root:zfsalert`, sumy md5 obu crontabów
  (root `976e16cd…`, zfsbackup `70e7bc0b…`) identyczne przed i po.
- Poprzedni stan floty: **2026-08-04 23:44**, trzy osiągalne
  hosty na `a567328`, `audit clean` na każdym, kolejki poczty puste.
  **Zastrzeżenie (REV-20260806-046):** tamten `audit clean` obejmował werdykt
  alertów sprzed poprawek — dowodził obecności MTA i pustej kolejki, NIE
  zdolności dostarczenia. Nie używać go jako dowodu, że poczta z tych hostów
  wychodzi; dowodem dostarczalności pozostaje wyłącznie próbka `--test-mail`
  z obserwacją kolejki (i tak ograniczona do „opuściło ten MTA")
- **Kampania enrolmentu (Gates A-J, REV-037…044): ZAMKNIĘTA.** Recenzent
  ACCEPTED w `docs/internal/reviews/REV-20260804-044-FINAL-AJ-VERDICT.md` —
  wszystkie dziesięć bramek PASS, REV-037 przez REV-043 CLOSED, zero
  otwartych findingów blokujących wydanie w tej kampanii. Odpowiedź
  implementera nie jest wymagana, chyba że kolejny commit zmieni
  zrecenzowane zachowanie lub unieważni zapisany dowód.
- **Werdykt o dostarczalności alertów (2026-08-04).** Do tej pory `deploy.sh`
  sprawdzał wyłącznie `command -v mail`, co dowodzi istnienia *klienta*, nie
  zdolności dostarczenia. Na Proxmoksie nie było tego widać, bo instalator PVE
  konfiguruje postfixa; na czystym Debianie wdrożenie kończyło się sukcesem na
  hoście, którego alerty nigdy nie wychodzą — ta sama klasa co „quiesce zwrócił
  rc=0 i nic nie zamroził". Nowe `mta_present`/`mta_name`/`mail_queue_depth`/
  `alert_delivery_verdict`: werdykt w KAŻDYM trybie, w tym `--check-only`, plus
  sprawdzenie kolejki po teście maila (dotąd „wyślij i miej nadzieję" —
  instrukcja kazała operatorowi zajrzeć do skrzynki ręcznie).
  **Postfix celowo nietykany** — decyzja właściciela: to zmiana ogólnohostowa,
  a host z działającym exim4/relayem straciłby konfigurację; wybór smarthosta i
  poświadczeń SMTP jest per instalacja. Ta sama zasada co nietykanie cudzych
  grantów ZFS i cudzych bloków crona. Świadomie NIE wnioskujemy o zdolności
  wysyłki na zewnątrz z `main.cf`: debianowe „Local only" ustawia
  `inet_interfaces=loopback-only`, co blokuje ODBIERANIE i nic nie mówi o
  wysyłce — jedynym uczciwym sygnałem jest kolejka po realnej próbie.
  **REV-20260806-046 (2026-08-06, P1): pierwsza wersja werdyktu sama orzekała
  zdrowie z braku dowodów** — dokładnie ta klasa, którą miała eliminować.
  Trzy findingi, wszystkie IMPLEMENTED, po jednym commicie na finding:
  1. **F2 (`c668b51`):** nieczytelna kolejka logowała „unverified" ale
     zwracała 0, więc host, którego kolejki nikt nie umiał obejrzeć, kończył
     `audit clean`. Do tego `postqueue`, który sam padł, wpadał w awk-owe
     `END{print 0}` i czytał się jako PUSTA kolejka, a nienumeryczne wyjście
     prześlizgiwało się obok `[ -gt 0 ]` do zdrowej gałęzi. Wszystkie trzy
     kształty teraz fail-closed: UNVERIFIED = `warn()` = `PROBLEMS` =
     `--check-only` wychodzi niezerowo.
  2. **F1 (`b4de04a`):** pusta kolejka drukowała „this host can send" —
     pewny pozytyw wywiedziony z nieobecności zakolejkowanej pracy, przy
     zablokowanym porcie 25 tak samo jak przy sprawnym relayu. Teraz:
     „prerequisites OK; actual delivery UNVERIFIED in this run".
  3. **F3 (`d859af5`):** blok test-maila wyjęty do `alert_delivery_probe()`;
     status `mail(1)` jest sprawdzany (był fire-and-forget), a opróżniona
     kolejka twierdzi tylko tyle, ile trzysekundowe spojrzenie dowodzi:
     „the message LEFT THIS MTA; recipient delivery is NOT independently
     verified" zamiast „accepted and dispatched it".
  Nowa suita **`test/alertmail/run.sh` 18/18** (zarejestrowana w grafie):
  kwartet funkcji na podstawionych `mail`/`postqueue`/`sleep` + wyjęty
  z deploy.sh oryginalny `warn()`, każdy przypadek sprawdza zgodność kodu
  powrotu, licznika `PROBLEMS` i emitowanego brzmienia; przypadki regresyjne
  F1/F2 padają na zrecenzowanej bazie `a567328` (`DEPLOY_SRC=` wspiera
  uruchomienie suity przeciw dowolnej wersji deploy.sh).
  **Dwa znaleziska produkcyjne — oba NAPRAWIONE i zweryfikowane na żywo
  2026-08-04 23:44, na polecenie właściciela wydane po zgłoszeniu.** Nowy
  werdykt zwrócił się dwukrotnie przy pierwszym uruchomieniu:
  1. **metropolis pve2: `/etc/aliases.db` nie istniał.** Sam `/etc/aliases`
     leżał tam od 2023-03-22, ale skompilowanej bazy nigdy nie zbudowano, więc
     postfix odbijał każdą przesyłkę idącą przez alias z `(alias database
     unavailable)` — w kolejce siedział bounce od 09:37 tego dnia. To nie był
     jeden zablokowany list: **każdy alert kierowany aliasem na tym hoście
     lądował w kolejce zamiast dojść.** `newaliases` + `postqueue -f`;
     zaległa wiadomość faktycznie doszła (`status=sent (250 2.0.0 Ok: queued
     as 44CB32BE0FB1)`, relay `lurk.com.pl[89.161.153.182]:25`), kolejka pusta.
  2. **pve0: brak `/var/lib/zfs-snapshot-all/locks`** (katalog nadrzędny i
     `notify-state` były na miejscu — brakowało wyłącznie tego jednego).
     Znaczyło to, że `lib-cron.sh` odmówiłby KAŻDEGO zapisu crontaba na tym
     hoście; nic tego akurat nie robiło, więc stan był niemy. Naprawione przez
     zwykły `bash deploy.sh` — narzędzie będące właścicielem tego katalogu, nie
     ręczny `mkdir` — powstał z uprawnieniami identycznymi jak na pozostałych
     hostach (`2775 root:zfsalert`). Ze względu na incydent z mutacją crontaba
     na TYM hoście (patrz historia `$0` vs `BASH_SOURCE[0]`) sumy kontrolne
     zabezpieczone przed i po: `root` `a52e3b31…` → `a52e3b31…`, `zfsbackup`
     `6b9b15c4…` → `6b9b15c4…`, 8 linii zadań bez zmian. Bajt w bajt.

  Stan floty po naprawach: `locks` OK, `aliases.db` OK, kolejka 0 i
  `audit clean` na wszystkich trzech osiągalnych hostach. Obie usterki należą
  do tej samej rodziny co reszta historii tego projektu — **nie awarie, tylko
  cisza tam, gdzie powinien być sygnał**; żadna nie zgłaszała się sama, dopóki
  `--check-only` nie zaczął pytać o dostarczalność alertów.
- **Recenzje przeniesione do `docs/internal/reviews/` (2026-08-04).** `git mv`,
  więc historia zachowana; 109 odwołań w 12 plikach przepisanych, w tym
  protokół w `CLAUDE.md`, `AGENTS.md` i `docs/AI_PROJECT_RULES.md`. Powód:
  `docs/` zawierało 52 pozycje archiwum procesu recenzyjnego wobec 5 plików
  dokumentacji właściwej — ktoś obcy otwierał katalog dokumentacji i widział
  rejestr wewnętrzny. Żadne odwołanie w `.sh` nie było ścieżką wykonywaną,
  wyłącznie komentarze, więc zmiana jest bezbehawioralna.
  **UWAGA DLA RECENZENTA:** recenzent publikuje `REV-*.md` przez commit gita.
  Nowa ścieżka to `docs/internal/reviews/` — plik wrzucony pod starą
  `docs/reviews/` odtworzy katalog i rozjedzie kanał na dwie lokalizacje.
- **Przygotowanie do publikacji (2026-08-04): licencja MIT + usunięcie wartości
  jednej instalacji z `deploy.sh`.** Trzy rzeczy, które sprawiały, że pakiet
  nadawał się do użytku wyłącznie dla autora:
  1. **Brak `LICENSE`** — formalnie nikt nie miał prawa tego użyć. Dodany MIT.
  2. **`REPO_URL` zaszyty na `AdalbertKing/zfs-snapshot-all`** — to był realny
     defekt, nie kosmetyka: KAŻDY fork wdrażał hosty, które co godzinę
     ciągnęły cudzy `main`. Własne commity nigdy nie dotarłyby na własne
     maszyny, a zmiana z upstreamu lądowałaby u nich bez recenzji. Teraz
     wyprowadzany z `git remote get-url origin` checkoutu, w którym leży sam
     `deploy.sh` — jedyna odpowiedź poprawna zarówno dla upstreamu, jak i dla
     forka. Zweryfikowane w trzech przypadkach: prawdziwy checkout (zwraca
     dokładnie dotychczasową zaszytą wartość, więc **istniejące hosty nie
     widzą żadnej zmiany**), katalog bez gita (fallback), nadpisanie ze
     środowiska (wygrywa).
  3. **`NOTIFY_EMAIL` domyślnie na adres autora** — świeża instalacja cicho
     wysyłałaby alerty obcej osobie, a operator nigdy by się nie dowiedział,
     że coś się zepsuło. Domyślnie `root` (poczta lokalna, zawsze
     dostarczalna). Bezpieczne dla floty: `/etc/zfs-alert.conf` istnieje na
     wszystkich hostach (sprawdzone na żywo) i nigdy nie jest nadpisywany, a
     jego `ZFS_ALERT_EMAIL` wygrywa w czasie działania.

  `BACKUP_USER_DATASETS="rpool/data rpool/ROOT/pve-1"` **celowo zostawione** —
  wstępna ocena mówiła, że to wartość jednej instalacji, pomiar ją obalił:
  `rpool/ROOT/pve-1` jest identyczne na trzech hostach o różnych nazwach
  (pve0, pve1, pve2), czyli to konwencja instalatora PVE, nie lokalna ścieżka.
  Dopisany komentarz wyjaśniający, skąd ta wartość, plus wskazanie
  `--datasets=` dla hostów spoza Proxmoksa. Naprawiony też placeholder
  `# Author: [Your Name]` w `snapsend.sh`/`snapget.sh`.

  Testy: 8 lokalnych suit wymaganych przez graf — `join` 82/82,
  `joinmanifest` 10/10, `joinremote` 8/8, `twins` 24/24, `draftscope` 26/26,
  `pause` 74/74, `quiescehelper` 119/119, `selfupdate` 28/28 (7 SKIP);
  łącznie 371, zero błędów. Suity wymagające roota/ZFS (`snapsend`,
  `scenarios`) i drugiego hosta (`remote`) są przez graf wywołane zmianą w
  `snapsend.sh`, ale ta zmiana to **wyłącznie jedna linia komentarza**
  (nagłówek autora) — co potwierdza niezależnie zielony wynik `twins`,
  normalizującej komentarze.
- **Scalenie `snapsend.sh`+`snapget.sh` w jeden silnik: ROZWAŻONE I ODRZUCONE
  (2026-08-04).** Zamiast tego dodano alarm dryfu (`test/twins`, suita niżej,
  kontrakt `twin-functions` w `test/deps.conf`). Powód odrzucenia, zmierzony a
  nie oszacowany: łatwa deduplikacja jest już zrobiona (`lib-zfs-snap.sh` ma 81
  funkcji i 2527 linii — więcej niż każdy z tych skryptów osobno), a to co
  zostało to nie duplikacja tylko **rozbieżność** (`process_dataset` różni się w
  450 z ~550 linii, `find_conflicting_snapshots` w 53 z 57 — push czyta lokalnie
  i pisze zdalnie, pull odwrotnie, więc kontrole bezpieczeństwa siedzą po
  przeciwnych stronach). Kluczowe ryzyko: pięć funkcji naprawdę bliskich
  identyczności ma IDENTYCZNE sygnatury i nazwy parametrów (`src_dataset`,
  `tgt_dataset`, `remote_user`, `remote_host`), a różnią się wyłącznie tym,
  której stronie doczepiane są współrzędne zdalne. Scalenie wymaga parametru
  kierunku, którego jedyny tryb awarii jest cichy i **fail-open** przy
  wykrywaniu wspólnej bazy — a `test/snapsend` jest z założenia LOCAL MODE ONLY
  (`validate_remote_host()` słusznie przerywa przy tym samym `/etc/machine-id`),
  więc suita, która miałaby to złapać, strukturalnie nie może: przy pustych
  `remote_user`/`remote_host` obie gałęzie zwijają się do tego samego wywołania.
  Uzasadnienie „scalmy przed tuningiem VPN/buforów" z 2026-07-20 również
  wygasło: pokrętła (`BUFFER_SIZE`, `MEMORY`, `BWLIMIT_FLAG`, `COMPRESS_PIPE`)
  są już wspólnymi zmiennymi w obu plikach, różni się tylko kształt potoku
  (~6 linii), a rozmiar bufora zmierzono jako nieistotny.
- Ostatnia zmiana zachowania produkcyjnego: **REV-20260804-042/043 —
  Gate G i Gate I kampanii enrolmentu zamknięte na żywo, dwa realne błędy
  znalezione i naprawione, plus jedna P1 korekta recenzenta zanim
  cokolwiek trafiło do wdrożenia.**
  1. **Gate G (route-switch): PASS na żywo.** Throwaway LXC (`/dev/zfs`
     passthrough przez cgroup — WAŻNE: bez `lxc.mount.entry`, ta
     dyrektywa psuje auto-mount `/proc` kontenera; sam cgroup allow
     wystarcza) na metropolis pve1, dwie niezależne ścieżki sieciowe
     (LAN + efemeryczny most `ip link add`, nigdy nie zapisany do
     `/etc/network/interfaces`). Pełny cykl: enroll+seed+activate po
     LAN → `final-catchup` → `set-endpoint` na drugą ścieżkę →
     `verify-endpoint` → `activate-client` → realny przyrost danych po
     nowej trasie, potwierdzony bajt w bajt. Po drodze znaleziony
     realny bug: `assert_target_block_not_clobbered` porównywał linie
     crona dosłownie, więc KAŻDA zmiana endpointu wyglądała jak cudzy
     job znikający i FATAL-owała reaktywację (`2e02a7d`). Recenzja
     złapała PRZED wdrożeniem, że ta pierwsza łatka była za
     gruboziarnista — jeden wspólny `HostKeyAlias` dla wszystkich
     jobów klienta mógł zamaskować cichą utratę JEDNEGO datasetu, jeśli
     inny dataset tego samego klienta przetrwał pod nowym adresem
     (REV-20260804-043, P1). Naprawione precyzyjnie: normalizacja
     WYŁĄCZNIE mutowalnego `host` w `-A "acct@host:path"`, reszta
     tożsamości joba (konto, source, target, harmonogram) musi się
     zgadzać dokładnie (`3a89892`). `test/zfsbackup` **260/260**
     (dokument twierdził tu `263/263` — zmierzone 2026-08-04 dwukrotnie,
     na HEAD i na `b4d1624` sprzed przeniesienia recenzji: obie dają 260,
     a suita ma `needs = nothing` i zero warunków od roota/ZFS, więc jest
     deterministyczna. Liczba 263 była błędna, nie środowiskowa),
     regresja potwierdzona (stash samej łatki → dokładnie te dwa nowe
     testy padają, reszta zielona). Gate G ponownie uruchomiony na żywo
     z poprawioną bramką — czysto, bez FATAL.
  2. **Gate I (sync na nieklastrowanej parze): PASS na żywo**, po
     korekcie metodologii ujawnionej wprost, nie wygładzonej. Pierwsza
     próba (ten sam LXC co Gate G) znalazła realny bug w `do_pair`:
     `--mode=sync` celowo nie ma `--target`, więc `PEER_TARGET` jest
     pusty, a kod tworzył `"$PEER_TARGET/$label"` bezwarunkowo dla
     KAŻDEJ roli pull — dla sync zwija się to do `/$label`, `zfs
     create -p` słusznie odmawia. Sync mode nigdy wcześniej nie parował
     się z żywą infrastrukturą. Naprawione: pomiń pre-tworzenie celu,
     gdy nie ma targetu (`d58e847`). Po naprawie ujawnił się GŁĘBSZY
     problem: privileged LXC dzieli JĄDRO i przestrzeń nazw puli z
     hostem — dla sync mode (ścieżka 1:1, bez prefiksu) "źródło" i
     "cel" okazały się DOSŁOWNIE tym samym datasetem
     (`zfs list -r hdd/backuptest_targets` pokazywał jeden wpis, nie
     dwa). Kontener nie mógł tego udowodnić strukturalnie — dwie
     zaimportowane pule o tej samej nazwie w jednym jądrze to
     sprzeczność. Owner zdecydował: zbuduj prawdziwą VM zamiast
     akceptować częściowy dowód. Zbudowano `labvm` (Debian 12
     cloud-init, WŁASNE jądro `6.1.0-51-cloud-amd64`, `zfs-dkms`
     skompilowany od zera po poprawce złego wariantu nagłówków —
     pierwsza kompilacja trafiła w `linux-headers-amd64` zamiast
     `-cloud-amd64` i dała moduł, który się nie ładował), własna pula
     `testsync` na drugim wirtualnym dysku (GUID
     `7174827982115380259`), niezależna od dopasowanej nazwą puli
     `testsync` utworzonej OSOBNO na pve1 (GUID `6403485474931656966`).
     Pełny cykl (seed + realna zmiana + druga synchronizacja)
     zweryfikowany po GUID snapshotu (identyczny po obu, naprawdę
     niezależnych stronach) i zawartości pliku. Po drodze: kolizja
     UID 1000 z prawdziwym produkcyjnym kontem `zfsbackup` w PIERWSZYM
     (już zniszczonym) kontenerze LXC — ujawniona natychmiast, brak
     trwałego wpływu (`zfs allow` na `rpool/data`/`rpool/ROOT/pve-1`
     zweryfikowany bez zmian), w drugiej próbie zapobieżona jawnym
     `UID_MIN 5000` przed jakimkolwiek `useradd`.
  3. **Sprzątanie: zero rezydualnych zmian.** VM i LXC zniszczone,
     efemeryczny most usunięty, throwaway pula `testsync` na pve1
     zniszczona z plikiem backingowym, wszystkie datasety testowe
     usunięte, klucze parowania i wpisy `known_hosts` wyczyszczone.
     Crontaby (root i `zfsbackup`) potwierdzone bajt w bajt identyczne
     z bazową linią sesji; `zfs allow` na realnych datasetach
     produkcyjnych bez zmian; `deploy.sh --check-only` → `audit clean
     on pve1`. Pełny rejestr: `docs/internal/reviews/responses/REV-20260804-042.md`,
     `docs/internal/reviews/responses/REV-20260804-043.md`.
- Wcześniej: **REV-20260804-039/040/041 —
  drugi krąg werdyktu recenzenta nad kampanią enrolmentu: cztery kolejne
  findingi, wszystkie zamknięte na żywo.**
  1. **F1 (039): przerwany `--join-remotely` — DISPUTED z dowodem, nie
     naprawiony nową maszyną stanów.** Świadomie zabity dwukrotnie w
     trakcie edycji zakresu (prawdziwy SIGTERM), potem zwykły retry TEJ
     SAMEJ komendy, bez ręcznej ingerencji: `do_pair` już ponownie używa
     istniejącego klucza (nie generuje nowego), `do_join` już traktuje
     ponowne zgłoszenie tego samego fingerprintu jako potwierdzenie, nie
     rotację — `authorized_keys` pozostał na jednej linii przez obie
     próby. Jedyna realna luka: komunikat błędu nie mówił, że retry jest
     bezpieczny — naprawione (`fef2314`).
  2. **F2 (039)/F1 (041): `remove-client` na ostatnim kliencie.** Gdy nie
     zostają żadne sekcje `[dataset:]`/`[prune:]`, `remove-client` prosi
     wspólny writer crontaba (`cron_block_remove`, ten sam co `--pause`)
     o usunięcie CAŁEGO bloku `zfs-backup-managed`, potem podmienia plik
     configu. Recenzja złapała, że nieudana podmiana pliku tylko
     ostrzegała i kontynuowała w `--unpair`/`STATE=removed` — teraz
     odmawia zamknięte, nazywa dokładnie stan mieszany, nigdy nie
     dociera do `--unpair`. `test/zfsbackup` +7 (255/255). Żywo:
     throwaway kolektor z JEDNYM klientem, crontab przed=dokładnie jeden
     zarządzany blok, po=ZERO bloków, checksum identyczny z bazową linią
     kampanii.
  3. **F3 (039)/REV-040: osierocone granty ZFS po UID.** Pierwsza wersja
     `--leave` (nowa komenda tear-down po stronie peera) zgadywała
     osierocony UID skanując `zfs allow` — recenzja złapała PRZED
     wdrożeniem, że to mogłoby odwołać cudzy grant na tym samym
     datasecie. Naprawione: trwałe `PEER_JOIN_ACCOUNT_UID` zapisywane
     przy joinie, weryfikowane przy każdym grantcie (odmowa zamknięta
     przy dryfie nazwa/UID), `--leave` używa WYŁĄCZNIE tego zapisanego
     UID. Żywo: dwa konta na jednym datasecie — obcy grant przetrwał
     nietknięty; dwa osierocone UID-y — tylko własny odwołany; legacy bez
     zapisanego UID i bez żywego konta — odmowa zamknięta, nic
     nietknięte; dryf UID/nazwy — odmowa PRZED mutacją.
  4. **F4 (039): macierz bramek.** Gate E (parent/child) i Gate H
     (idempotentna reaktywacja + odmowa przy pauzie) — PASS na żywo. Gate
     B — zamknięty dowodem z F1 powyżej. Gate G (zmiana trasy) i Gate I
     (sync na nieklastrowej parze) — jawnie NOT RUN: Gate G bo ta para
     hostów ma dokładnie jedną ścieżkę sieciową; Gate I bo metropolis i
     drugi klaster (192.168.11.x) siedzą na wzajemnie nieosiągalnych
     VPN-ach (potwierdzone w obie strony) — żaden dostępny w tej sesji
     hostpair nie jest jednocześnie nieklastrowany I wzajemnie osiągalny.
     Pełny rejestr: `docs/internal/reviews/responses/REV-20260804-039.md`.

- Wcześniej: **REV-20260804-037/038 — pełna
  żywa kampania enrolmentu (Gate A-J), osiem błędów znalezionych i
  naprawionych na żywo, zero fabrykowanych dowodów.** Kolektor pve1
  ↔ peer/source pve2 (metropolis), throwaway dataset, od czystego stanu do
  pełnego demontażu. Skrót ośmiu poprawek (każda to osobny commit, pełny
  opis w `docs/internal/reviews/responses/REV-20260804-037.md`'s Gate ledger i
  `REV-20260804-038.md`):
  1. `deploy.sh do_join()`: brakujący `local PEER_CONF_MODE` — pierwszy
     realny `--join --mode=` na żywym drugim hoście od razu się wywalił
     (`unbound variable`) w trakcie zapisu manifestu.
  2. `deploy.sh`: manifest join staje się atomowym, weryfikowanym commitem
     (render→temp→weryfikacja→rename→weryfikacja), zamiast niesprawdzanego
     `cat > plik` PO mutacjach konta/klucza (REV-038, `verify_join_manifest`,
     `test/joinmanifest` 10/10, +3 dla pola UID).
  3. `deploy.sh`: F1 z REV-037 — zdalny edytor `--join-remotely` mógł
     zgłosić fałszywy sukces po nieudanym drafcie; wydzielona
     `remote_scope_stage` z rozróżnialnymi kodami wyjścia
     (`test/joinremote` 8/8).
  4. `deploy.sh` (×2 miejsca): instrukcje `./deploy.sh --join=...`
     zakładały uruchomienie z `/root`, a skrypt leży w `$REPO_DIR` —
     dotyczyło też instrukcji ręcznych drukowanych od zawsze, pierwszy raz
     ktokolwiek wykonał je dosłownie.
  5. `zfs-backup.sh resolve_mode_datasets`: pobierał zatwierdzony plik
     zakresu pod złą etykietą (`LOAD_LABEL` = adres peera, zamiast
     `hostname -s` kolektora) — nowy globalny `COLLECTOR_LABEL`.
  6. `snapget.sh` — **KRYTYCZNE, dotyczy całej floty**: bramka
     bezpieczeństwa `-F` z plasterka 8 odmawiała KAŻDEGO pierwszego seeda
     (cel jest zawsze wstępnie tworzony pusty, co czyniło
     `target_exists()` zawsze prawdziwym).
  7. `snapget.sh` — **KRYTYCZNE, dotyczy całej floty**: `written@`
     porównywało sformatowaną wartość zfs (`"0B"`) z gołą cyfrą (`"0"`) —
     odmawiało przy KAŻDEJ zerowej rozbieżności, czyli normalnym stanie
     większości zwykłych incrementali w produkcji.
  8. `snapget.sh`: `written@` pytało o migawkę pod nazwą ŹRÓDŁA względem
     CELU — po dopasowaniu przez GUID (migawka zmieniona nazwą) cel nie
     ma migawki o tej nazwie, zapytanie zwraca `"-"`, odmowa mimo zera
     rozbieżności. Złapane przez WŁASNY istniejący test `test/snapsend`
     (sekcja guid-match), uruchomiony na żywo pierwszy raz od plasterka 8.

  `test/snapsend` **202/202** na pve1 (pierwszy przebieg od plasterka 8 —
  root+zfs nie było dostępne w sesji implementującej ten plasterek).
  Pełny cykl enrolmentu potwierdzony end-to-end: add-client → join
  (ręczny i zdalny) → draft/edit/commit-scope → seed (real transfer,
  md5 zgodny) → final-catchup (real incremental) → verify-endpoint →
  activate-client (dokładnie jeden zarządzany blok crona, reszta
  nietknięta, ręczne wykonanie jak prawdziwy cron: rc=0) → remove-client
  → pełny demontaż (crontab bajt-w-bajt jak przed testem na obu hostach,
  zero rezydualnych grantów/kont/holdów).

  **Dwie ujawnione, nienaprawione luki** (odzyskiwalne ręcznie,
  low-impact dziś): `remove-client` nie potrafi usunąć OSTATNIEGO klienta
  z configu (gen-cron.sh odmawia pustego zestawu reguł); przerwany
  `--join-remotely` może zostawić poprawnie dołączonego peera bez wpisu
  po stronie kolektora (odzyskiwalne przez ponowny `add-client`, do_join
  traktuje to jako rotację).

- Wcześniej: **REV-20260802-033 plasterek 10**
  (korekty nazewnictwa ról) — trzy komunikaty w `zfs-backup.sh`
  (`cmd_seed`, `cmd_final_catchup`, `cmd_verify_endpoint`) nazywały peera
  "the source" tuż obok już poprawnego "this collector" dla maszyny, która
  faktycznie się przenosi (ten sam defekt co U9 w subtelniejszej postaci —
  czytelnik widzi "collector relocates", a zdanie później "the source" bez
  sygnału, że to już druga strona). Zmienione na "the peer", zgodnie ze
  słownictwem używanym wszędzie indziej w pliku (`$PEER_HOST`, "the peer's
  committed scope file"). Wyłącznie literały napisów — zero zmiany
  zachowania. `zfsbackup` **249/249** (+3, sekcja 41, source-grep piny wzorem
  38a). Tym samym WSZYSTKIE dziesięć plasterków z planu REV-20260802-033
  jest zaimplementowanych; jedyne co zostaje przed wdrożeniem to żywy test
  end-to-end na dwóch hostach (zadanie stojące, patrz niżej). Odpowiedź:
  "Slice 10" w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 9**
  (zdalny `--join` + edytor zakresu przez `ssh -t`, U10) — jedna jawna,
  domyślnie WYŁĄCZONA flaga `--join-remotely` na `deploy.sh --pair`
  (przekazywana bez zmian przez `zfs-backup.sh add-client`). Po zapisaniu
  wsadu i przypięciu klucza hosta (bez zmian), gdy flaga podana: `scp` wsadu
  na peera, zdalne `ssh ... deploy.sh --join=...` (bezpieczne, bo `--join`
  od U2 nie nadaje żadnych uprawnień — zakłada tylko konto), a dla parowania
  trybowego dodatkowo `ssh -t ... deploy.sh --draft-scope=...; $EDITOR
  <plik>` — `vi` biegnie na peerze, w terminalu admina siedzącego przy
  kolektorze. Finalizacja (`--commit-scope`, grant) NIGDY nie jedzie zdalnie
  pod żadną flagą — to zostaje ręczną, jawną komendą operatora w tej samej
  sesji `ssh -t`. Manifest peera zapisuje pochodzenie zdalne
  (`PEER_JOIN_REMOTE`/`_FROM`/`_AT`/`_SESSION`, ta ostatnia przechwycona
  LOKALNIE na peerze w chwili `--join`, nie deklarowana przez kolektor) —
  nowe, opcjonalne pole wsadu `PEER_CONF_REMOTE_JOIN=yes` niesie to z
  kolektora, dopisane do ścisłej listy dozwolonych kluczy peer.conf. Każda
  nieudana próba automatyzacji ostrzega i spada do dokładnie tych samych
  ręcznych instrukcji co dotychczas — awaryjna droga ręczna zostaje.
  `join` **82/82** (+5), `zfsbackup` **246/246** (+2). Odpowiedź: addendum
  "Slice 9" w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **korekta U9** (model endpointu,
  naprawiona natychmiast po zgłoszeniu, nie odłożona do plasterka 9/10) —
  `ACTIVE_ENDPOINT` uogólnione ze slotu nazwanego (`lan`/`vpn`) na dosłowny
  `"host:port"` (dwukropek nigdy nie występuje w nazwie hosta, więc to
  jednoznaczny rozróżnik wobec starego kształtu, bez osobnego pola wersji).
  `set-endpoint NAME --host=HOST[:PORT]` zastępuje `--lan=`/`--vpn=` — realna
  łamiąca zmiana CLI, zero promienia rażenia dziś (żaden klient we flocie nie
  używa endpointu innego niż domyślny). Podanie adresu JUŻ aktualnego jest
  teraz no-opem (bez bramki, bez zapisu) — to czyni "trasa VPN nie wymaga
  set-endpoint" prawdą konstrukcyjną, nie tylko nawykiem operatora. Nowe pole
  `ENDPOINT_KNOWN` (lista adresów, które kiedyś zadziałały): `verify-endpoint`
  po nieudanej próbie aktualnego adresu próbuje po kolei każdego znanego
  kandydata zamiast od razu prosić operatora o nowy; adres, który odpowie,
  zostaje AWANSOWANY na `ACTIVE_ENDPOINT`, a ten, który przestał odpowiadać,
  sam staje się znanym kandydatem. Migracja rekordu legacy (pierwsze
  `set-endpoint` po aktualizacji) dokłada do `ENDPOINT_KNOWN` też uśpiony
  drugi slot (ten, który NIE był aktywny) — nic nie ginie. Naprawiono też
  drugie potwierdzone w U9 ustalenie: komunikaty `final-catchup`/`seed` już
  nie nazywają złą maszyną tej, która się przenosi ("ten kolektor", nie
  "źródło"). Koszt jednorazowy dla istniejących klientów, nazwany wprost: ich
  ostatni catch-up sprzed aktualizacji (zapisany jako `lan`/`vpn`) nie
  dopasuje się do nowego porównania dosłownego adresu przy pierwszym
  `set-endpoint` po aktualizacji — czyta się jako "brak catch-upu", fail-closed,
  nie jako zaufanie rekordowi w formacie, którego nowa bramka już nie
  rozpoznaje. `zfsbackup` **244/244** (+6 netto nad plasterkiem 8, po
  przepisaniu — nie tylko dopisaniu — fixture'ów bramki `set-endpoint` na
  nowe CLI). Odpowiedź: "U9 implemented" w
  `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 8**
  (kontrakty sync: F3, U7, U8) — dwie niezależne połówki. (1) `snapget.sh`,
  `process_dataset`: `-F` przestało być bezwarunkowym domyślnym flagiem przy
  KAŻDYM odbiorze (dotyczy więc też dzisiejszego ruchu backup) — nowy
  `recv_force_flag` odmawia zamiast cicho nadpisywać, gdy cel to dysk ŻYWEGO
  guesta (`guest_disk_is_live`, reużywa `quiesce_guest_id`/
  `quiesce_guest_status` z `lib-zfs-snap.sh`, fail-closed gdy stanu nie da
  się ustalić), gdy brak wspólnego snapshotu po GUID (pełny resend wymaga
  jawnego `-f`), albo gdy `written@<wspólny>` > 0 (nazywa ilość). `-F`
  zostaje TYLKO przy kontynuacji własnej, nierozjechanej kopii, gdzie jest
  operacją pustą. Dowód (2026-08-02, klaster 192.168.11.x): `snapget.sh -r
  pve0:rpool/data/vm-100-disk-0` (sync bez drugiego argumentu) celowałoby w
  żywy dysk vsql2 (VM 100) i cofnęłoby bazę do repliki pvesr — dziś ratuje
  przed tym wyłącznie `dataset is busy` samego ZFS, nie własność
  bezpieczeństwa. (2) `deploy.sh --pair --mode=sync`: peer będący członkiem
  TEGO SAMEGO klastra PVE jest odrzucany PRZY ENROLLMENCIE (U8), zanim
  cokolwiek zostanie sparowane — sprawdzane tanio przez `/etc/pve/nodes/`
  (`PVE_NODES_DIR`, nadpisywalny jak `QUIESCE_PVE_DIR`, więc testowalny bez
  prawdziwego klastra); ograniczenie: dopasowanie po nazwie hosta, nie po
  tożsamości klastra — nazwane wprost, nie ukryte. (3) `zfs-backup.sh`:
  mapowanie F3 dla trybu sync wreszcie zaimplementowane — dotąd KAŻDE
  wywołanie `snapget.sh` z wrappera używało twardo mapowania backupowego
  (`$PEER_SAVED_TARGET/$LOAD_LABEL/$ds`), nawet dla `--mode=sync`, co dawało
  ścieżkę ze slashem na początku zamiast „ta sama ścieżka co źródło" —
  martwy kod od plasterka 5/6, nigdy nie przetestowany end-to-end. Nowe
  `snapget_local_base`/`client_local_path` to jedyne miejsce rozstrzygające
  tryb; `emit_client_sections` w trybie sync generuje jeden `[prune:$ds]` na
  dataset (`recursive = no`, bo nie ma wspólnego rodzica do zamiatania —
  inaczej byłby to ten sam wyścig `[prune:]`-pod-rekurencyjnym-`[prune:]`,
  który już raz naprawiono dla delsnaps). `zfsbackup` **238/238** (+6).
  **Korekta do plasterka 7:** U9 w `ENROLMENT-AGREED-2026-08-02.md` (ten sam
  wieczór, przed implementacją plasterka 7) już ROZSTRZYGNĄŁ, że sloty
  `lan`/`vpn` mają zniknąć z interfejsu na rzecz „jeden aktualny endpoint +
  lista znanych kandydatów" — przeoczone przy plasterku 7, potraktowane tam
  jako wciąż otwarte pytanie z samej recenzji. Nie cofnięte w już wypchniętych
  commitach plasterka 7 — zapisane jako otwarta korekta, do zrobienia razem z
  poprawką nazewnictwa ról (kolektor vs źródło), bo dotyczą tych samych pól i
  komunikatów. Odpowiedź: addendum "Slice 8" + "Correction to slice 7: U9"
  w `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 7**
  (model endpointu, F4) — recenzja żądała porównania stanu maszyny stanów z
  decyzjami właściciela 13-14 ("set-endpoint tylko gdy adres faktycznie się
  zmienia") i najmniejszej korekty. Ustalenie: maszyna stanów zbudowana pod
  REV-20260730-004/005 i REV-20260731-007/008 już to spełnia strukturalnie —
  `cmd_set_endpoint` nigdy nie mutuje rekordu bez jawnego `--lan=`/`--vpn=`,
  więc trasa VPN z niezmienionym `host:port` już dziś nie wymaga żadnego
  `set-endpoint` (wystarczy ponowne `verify-endpoint`). Dwie realne luki
  naprawione zamiast przebudowy: (1) `cmd_verify_endpoint` odrzucał stderr
  `snapget.sh` (`2>/dev/null`) na każdym nieudanym sprawdzeniu — dokładnie
  tam, gdzie miałoby się pojawić rozróżnienie „ograniczenie po adresie
  źródłowym" od zwykłej awarii (istniejący diagnostyk `snapget.sh`/
  `lib-zfs-snap.sh` dla ssh exit 255 był po prostu wyrzucany); teraz stderr
  trafia do pliku tymczasowego i jest wypisywany przy niepowodzeniu. (2)
  podpowiedź po `seed` sugerowała `set-endpoint`/`verify-endpoint` jako stały
  dwuetapowy ciąg — dokładnie błąd nazwany w F4 ("administrator wymyśla lub
  powtarza adres, który się nie zmienił") — przeformułowana na warunek:
  `set-endpoint` tylko gdy SSH łączy się teraz pod innym host:port, inaczej
  od razu `verify-endpoint`. Nazewnictwo ról w komunikatach (kolektor vs
  źródło jako przenoszona maszyna) świadomie odłożone do plasterka 10.
  `zfsbackup` **232/232** (+2). Odpowiedź: addendum "Slice 7" w
  `docs/internal/reviews/responses/REV-20260802-033.md`.
- Wcześniej: **REV-20260802-033 plasterek 6**
  (kolektor: fetch/digest/generate) — `zfs-backup.sh` przestaje wymagać listy
  datasetów przy `add-client --mode=backup|sync` (alternatywa dla
  `--datasets`, przekazywana do `deploy.sh --pair` jako `--mode=`).
  `resolve_mode_datasets()`, wpięte w `load_client_and_connection` (więc
  `seed`/`final-catchup`/`verify-endpoint`/`activate-client`/`migrate-profile`
  nie potrzebują ŻADNEJ zmiany), dla klienta trybowego: pobiera przez ssh
  plik zakresu peera ORAZ jego sidecar sha256 (T3), odmawia przy
  niezgodności, czyta przez `lib-scope.sh` (`scope_read`/`scope_includes` —
  realna krawędź źródłowa, nie duplikat) i przechodzi realne liście przez
  zdalne `zfs list -r`, wypełniając `PEER_SAVED_DATASETS` dokładnie tak, jak
  robił to dotąd ręcznie podany `--peer-datasets`. `cmd_seed` pomija swoje
  dotychczasowe wywołanie `--draft-config` (specyficzne dla listy
  datasetów) dla klienta trybowego — `resolve_mode_datasets` jest jego
  odpowiednikiem sprawdzenia gotowości/łączności.
  **Ważne dla recenzenta:** wynikiem jest GOTOWY, od razu instalowany config
  (istniejący mechanizm `PROFILE_GFS`/`emit_client_sections`), nie kandydaci
  do ręcznego przeglądu jak w starszej konwencji `do_draft_config` —
  to jest model uzgodniony w dyskusji zapisanej w
  `docs/discussions/ENROLMENT-AGREED-2026-08-02.md` (scenariusz odniesienia:
  „dostaję gotowy domyślny config… i zaczyna się backup”), nie coś
  wywnioskowane z samej recenzji.
  U11 (per-sekcyjny znacznik własności): `emit_client_sections` pisze
  `# managed-by: zfs-backup.sh client=<nazwa>` jako pierwszą linię treści
  każdej wygenerowanej sekcji `[dataset:]`/`[prune:]`; `remove_managed_sections`
  usuwa sekcję tylko gdy ten znacznik się zgadza ALBO ścieżka była już
  wcześniej zapisana we WŁASNYM `MANAGED_DATASETS`/`MANAGED_PRUNE_SCOPE`
  wywołującego (to drugie jest tym, co zachowuje działanie każdego klienta
  aktywowanego przed U11 bez zmian — ich sekcje sprzed znacznika są nadal
  rozpoznawane jako własne po własnym zapisie, znacznik dochodzi przy
  najbliższym przepisaniu). Dopasowanie nagłówka bez znacznika i bez
  wcześniejszego zapisu jest ODMAWIANE, nie cicho kasowane — wygląda na
  ręcznie napisaną sekcję w tym samym miejscu.
  U6/rozstrzygnięcie pytania 2: `ensure_cron_config` dopisuje globalny próg
  `keep = 2` dla wszystkich trzech zastrzeżonych prefiksów
  (`__replicate_`, `vzdump`, `__migration__`) przez `[excluded:]`, wyłącznie
  DOKŁADAJĄC brakujący próg — silniejszy `keep` operatora nigdy nie jest
  zawężany. `zfsbackup` **230/230** (+16). Odpowiedź: addendum "Slice 6" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej **łatki T3/U2/T5**
  (`6c930ff`, `b6d5032`) wobec `docs/discussions/ENROLMENT-AGREED-2026-08-02.md`
  — ten dokument, nie sama recenzja, jest właściwą specyfikacją mechaniki,
  do której plasterki REV-033 dążą. T3: `--commit-scope` zapisuje sha256
  pliku zakresu, z którego nadał (`<label>.scope.sha256`, world-readable) —
  kolektor (plasterek 6) porówna to przy fetchu, odmówi gdy się rozjedzie.
  U2: `--commit-scope` liczy i wypisuje CAŁY plan (grant/revoke/hold-blocked/
  gone) PRZED pierwszym `zfs allow`/`unallow`, nie odkrywa go linia po linii
  w trakcie wykonania. T5: `--draft-scope` dopisuje spis rodzin snapshotów
  (`__replicate_`, `automated_*`, `vzdump` itp.) obok inwentarza datasetów —
  zero kosztu, żadnej drugiej reprezentacji. Wszystkie trzy zweryfikowane na
  żywo na metropolis pve2 (T3/U2 na scratch datasetach, T5 na prawdziwych,
  bałaganiarskich danych produkcyjnych). `draftscope` **26/26** (+4).
  Odpowiedź: sekcja "Patches against ENROLMENT-AGREED" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 5** (`d839c91`) — `--pair --role=pull` przyjmuje teraz `--mode=backup|sync`
  jako alternatywę dla `--peer-datasets`: pakiet niesie `PEER_CONF_MODE`
  zamiast listy datasetów, wybór odsunięty na peera (`--draft-scope`/
  `--commit-scope`, plasterek 4). Wzajemnie wykluczające się z
  `--peer-datasets`. `--mode=sync` odmawia `--target` (F3: sync odtwarza
  ścieżki źródła jeden do jednego, brak osobnego korzenia docelowego);
  `--mode=backup` przyjmuje `--target` albo zostawia puste (domyślny cel
  "serwera" to `DEFAULT_TARGET` samego wrappera `zfs-backup.sh`, nie coś co
  `deploy.sh` wymyśla). Prawdziwa granica zaufania (`validate_peer_conf`,
  paczka przekracza hosty) sprawdzona: pakiet BEZ klucza `PEER_CONF_MODE`
  w ogóle (dokładny kształt każdej paczki sprzed tego commitu) waliduje się
  identycznie jak wcześniej — zgodność wsteczna potwierdzona osobnym
  testem, nie wywnioskowana z diffu. `join` **81/81** (+13).
  Odpowiedź: addendum "Slice 5" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 4** (`279303b`) — `deploy.sh --draft-scope=LABEL` generuje plik zakresu
  z prawdziwego inwentarza ZFS peera: jeden `[dataset:X]` na niesystemowy
  dataset jeden poziom pod każdą pulą (`include_parent=no`,
  `include_children=yes`), plus pełny inwentarz jako komentarz. Cenzus
  systemowy (`ROOT`, `swap`) dopasowywany WYŁĄCZNIE po ostatnim segmencie
  ścieżki, nigdy jako prefiks/podłańcuch — przykładowe korzenie z F2
  (`data`/`olds`/`LXC`) nie mogą zostać złapane przez sprytniejszą
  heurystykę. Odmawia, gdy plik zakresu już istnieje (chroni edycję w toku)
  albo manifest nie opisuje delegowanego peera pull. Zweryfikowane na żywo
  na metropolis pve2 (3 prawdziwe pule, w tym głęboko zagnieżdżona struktura
  backup-of-backup) — 9 aktywnych datasetów trafionych poprawnie, wszystkie
  3 korzenie puli + `rpool/ROOT` poprawnie wykluczone, pełny inwentarz
  (30 datasetów) zgadza się z ręcznym `zfs list -r`. `join` **64/64** (+10),
  nowa suita `draftscope` **22/22**. Odpowiedź: addendum "Slice 4" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260802-033 plasterek 3** (`b7e0478`) — `do_commit_scope` teraz też
  ODBIERA: zbiór do odwołania to
  (poprzedni zbiór z manifestu) MINUS (obecny zbiór ze scope file) — nigdy
  wyprowadzone z tego, co `zfs allow` pokazuje dla konta teraz, co jest tym,
  co sprawia że cudzy grant na tym samym datasecie przeżywa zawężenie: nigdy
  nie jest kandydatem, nie jest oszczędzony po rozważeniu. Kandydat z aktywnym
  holdem transferu (`zfssnapall_inflight`) zostaje NIE odwołany, ostrzeżenie
  po imieniu, zapisany z powrotem w manifeście do ponowienia przy następnym
  commit. Zweryfikowane na żywo na metropolis pve2 (scratchowe datasety):
  cudzy grant przeżył, dataset z holdem przeżył i został poprawnie odwołany
  po zwolnieniu holdu przy kolejnym uruchomieniu, dataset bez holdu odwołany
  od razu, manifest zgadza się z rzeczywistym stanem po obu przebiegach.
  Sprzątnięte: scratch datasety zniszczone, `--revoke-quiesce` użyty do
  usunięcia whitelisty/reguły sudoers które ten test stworzył.
  Odpowiedź: addendum "Slice 3" w
  `docs/internal/reviews/responses/REV-20260802-033.md`. Wcześniej
  **REV-20260803-036** —
  `--pause`/`--resume` z durable-transaction hardeningiem: zapis stanu
  `--fullcron` jest teraz durable PRZED zamianą crontaba (kolejność
  odwrócona, atomowy rename, rollback stanu przy nieudanym zapisie
  crontaba — F1); dokładny bajtowy placeholder zapisany obok stanu i
  porównywany bajt-po-bajcie przy `--resume` zamiast `grep` po podłańcuchu
  (F3); tryb blokowy renderuje wszystkie bloki lokalnie i commituje JEDNYM
  zapisem przez `cron_replace_all_impl`, więc częściowa pauza/resume nie
  jest już możliwa (F2); jawny rejestr `PAUSE_KNOWN_BLOCKS` — blok
  wyglądający syntaktycznie jak nasz (np. cudzy `certbot`) nigdy nie jest
  dotykany (F4); `lib-cron.sh` sam rozpoznaje zapauzowany kształt
  (`cron_paused_guard`) i odmawia KAŻDEMU zwykłemu pisarzowi
  (`cron_block_install`/`ensure_line`/`adopt_line`, czyli też
  `gen-cron.sh --install`) nadpisania go, więc pauza przeżywa zwykły zapis
  wykonany po jej zakończeniu, nie tylko zapis współbieżny (F5). `pause`
  **74/74** (+25). Odpowiedź:
  `docs/internal/reviews/responses/REV-20260803-036.md`. Wcześniej `f6f4ce3` —
  `deploy.sh --pause`/`--resume` domyślnie zatrzymuje TYLKO bloki tego
  pakietu (zakomentowanie ciała bloku w miejscu, markery `lib-cron.sh`),
  zamiast całego crontaba; `--fullcron` przywraca dawne zamiatanie całego
  crontaba dla usera, gdy operator naprawdę chce zatrzymać wszystko;
  `--resume` sam rozpoznaje tryb, w którym dany user został zapauzowany;
  wcześniej `54de481` — pierwsza wersja `--pause`/`--resume` (tylko tryb
  pełnego crontaba), zbudowana na zamku `lib-cron.sh`;
  wcześniej `9e977f6` — `CRON_LOCK_DIR` to teraz jeden stały katalog bez
  fallbacku zależnego od wywołującego (REV-035); wcześniej `4190d83` —
  `--join` (peer pull) nie nadaje już żadnych uprawnień
  ZFS; nowa komenda `--commit-scope` nadaje dokładnie to, co wybiera plik
  zakresu (REV-033 plasterek 2); wcześniej
  `ff712df` — gramatyka i czytnik pliku zakresu, `lib-scope.sh` (REV-033
  plasterek 1); wcześniej `41afa2f` — goły `exec ... 2>/dev/null`
  w `cron_lock_acquire`/`_release` trwale kasował stderr procesu zamiast
  gasić błąd jednej próby (REV-034, złapane przy zamykaniu F3); wcześniej
  `4f1c174` — `cron_replace_all` spina `migrate-to-account` na wspólnym
  pisarzu (REV-034 F3); `cecfeaf` — wspólny blok scalany zamiast
  nadpisywany, układ markerów sprawdzany globalnie (REV-034 F1, F4);
  `224cc83` — zamek per-użytkownik zamyka wyścig (REV-034 F2); wcześniej
  `700d045` — rejestr tego, co przebieg utworzył, przestaje być **plikiem**
  (REV-032); `3d4c13f` — raport wycofania nie może **zawieść fail-open**
  (REV-031); `9fbf1df` — niekompletny zestaw jest **usuwany, nie tłumaczony**
  (REV-030); `c7ce8da` — granica zamrożenia należy do **każdej puli**, nie do
  przebiegu (REV-029); `90a06c8` — `--add-quiesce`, grant **wyłącznie
  dokładający** (REV-028); `7564f8e` — ścieżka zdalna dostaje ten sam kontrakt
  co lokalna
- Repozytorium: `AdalbertKing/zfs-snapshot-all`
- Tryb pracy: tymczasowo bezpośrednio do `main`, decyzją właściciela
- Poprzedni **uzgodniony** punkt bazowy: `388a78e` z 2026-07-30 (sekcja 8)
- Status ogólny: **Cała flota (4 hosty) pracuje z kont delegowanych, każdy host
  ma własny config w `/etc/zfs-snapshot-all/`. Kolejka recenzji pusta, dług suit
  zerowy — wszystkie odpowiedzi na REV-021…032 są w
  `docs/internal/reviews/responses/`.** REV-032 przeszedł pełen komplet suit **przed**
  wejściem na `main` (gałąź `rev-032`, klon na metropolis pve1): `quiesce`
  161/161 jako konto, `snapsend` 202/202, `scenarios` 34/34, `remote` 145/145
  jako root i 145/145 jako konto. Migracja zaczęła się 2026-08-01 18:10 na
  metropolis pve1 i przy okazji **wykryła realny defekt fail-open w lokalnym
  quiescie** (`55d33a2`) — pierwszy przebieg jako konto zrobił pięć snapshotów
  bez zamrożenia i zakończył się kodem 0.

> **Jak ten defekt został znaleziony — warto, żeby nie zniknęło.** Nie przez
> kod błędu i nie przez alert: migracja zakończyła się sukcesem, job zwrócił 0,
> a dziennik napisał „guest 106 is not running”, podczas gdy `qm status` w tej
> samej sekundzie mówił `running`. Weryfikacja polegała na przeczytaniu, co
> quiesce *zrobił*, a nie na sprawdzeniu, czy się *udało*. Gdyby zatrzymać się
> na `rc=0`, host robiłby od tej nocy kopie crash-consistent, twierdząc w logu,
> że są zamrożone.

## JEDEN BLOK, JEDEN WLASCICIEL -- cicha utrata zadan (2026-08-29)

Znalezione przez sprzatanie po labie, nie przez test. `remove-client alfa` i
`remove-client beta` zdjely przy okazji **trzy zadania replik**, ktorych nie
dotyczyly. Nic o tym nie powiedzialy; zauwazylem, bo hash crontaba w niezwiazanej
linii audytu byl ten sam co PRZED zainstalowaniem replik.

Mechanizm: w crontabie jest **jeden** zarzadzany blok, wiec ten config, ktory go
ostatnio wyrenderowal, jest wlascicielem calosci. Polecenie rozwiazujace sie na
config B zastepuje kazda linie, ktora wstawil config A -- lacznie z zadaniami, o
ktorych B nigdy nie slyszal.

Czesciowo sam to na siebie sciagnalem, podajac `--config=/root/replab.conf` dla
labu zamiast kanonicznej sciezki. W normalnym wdrozeniu jest jeden config na
(host, konto) i kolizja nie powstaje. Ale cisza przy podmianie jest wada
niezaleznie od tego, kto ustawil sciezki.

**Blok od zawsze niesie `# Source: <sciezka>` w drugiej linii** -- porownanie
kosztuje jednego grepa. `atomic_replace_and_install`, czyli jedyne drzwi, przez
ktore przechodza wszyscy pisarze, mowi teraz oba adresy i co zniknie. Nie
odmawia: migracja configu na inna sciezke jest czynnoscia dozwolona, tylko nie
ma byc niema.

Sprawdzone na zywo: instalacja z `/root/other.conf` na bloku wyrenderowanym z
`/root/replab.conf` wypisala obie sciezki i ostrzezenie. W suicie przypiete
**strukturalnie** -- ze straznik istnieje, jest wolany z tych jedynych drzwi i
uzywa tego samego normalizatora sciezek co straznik brakujacego configu -- i tyle
ta suita moze uczciwie twierdzic.

Przy okazji potwierdzil sie INNY, wczesniejszy straznik, ktory dziala lepiej:
proba wpiecia repliki do configu prowadzacego crontab konta `zfsbackup`, przy
biegu rozwiazanym na `root`, zostala **odmowiona** z opisem obu wyjsc.

## REV-126: sonda dowodzila rzeczy o ZRODLE, nie o NOSNIKU (2026-08-29)

Wada moja, z tego samego dnia. `written@ == 0` mowi, ze zrodlo jest spokojne --
i nic nie mowi o dysku, ktorego wlasnie nie zamierzam otworzyc. A rotacja to nie
przypadek brzegowy, tylko **ksztalt, dla ktorego ta funkcja istnieje**:

1. nosnik A dostaje `s1` i jedzie do sejfu
2. nosnik B dostaje `s2`
3. zrodlo cichnie, wiec `written@s2 = 0`
4. wraca A -- i byl pomijany, **na zawsze**, wciaz na `s1`

Log mowil „nie ma czego kopiowac", co bylo prawda o zrodle i falszem o dysku.

### Czym to zastapione

Szybka sciezka potrzebuje faktu o NOSNIKU, i to takiego, ktory da sie zdobyc bez
importu -- inaczej optymalizacja kosztowalaby dokladnie to okno, ktore ma
oszczedzic. Dwie rzeczy to umozliwiaja: skan `zpool import` wypisuje `id:` kazdej
importowalnej puli **bez importu**, a `detach` zapisuje po ZWERYFIKOWANYM
transferze, ktory snapshot trzyma nosnik o tym GUID.

Pominiecie wymaga teraz trzech faktow naraz: zapisany GUID to dysk w kieszeni,
zapisany snapshot to wciaz najnowszy w rodzinie, i nic nie zapisano od tamtej
pory. Wszystko inne -- brak zapisu, zapis nieczytelny, inny dysk tej samej nazwy
puli, nosnik w tyle -- **importuje**.

Zapis awansuje wylacznie w `detach`, przy jeszcze zaimportowanej puli (jedyny
moment, w ktorym GUID jest czytelny), i tylko gdy ten bieg SAM importowal i
dostal `--engine-rc 0`.

### Dowod na zywo, trzy prawdziwe nosniki

```
1. A zsynchronizowany   -> guid=4001886776194565870  snap=rot_..._22-42-34
2. zrodlo dalej, B      -> guid=8124947038768651298  snap=rot_..._22-42-41
3. zrodlo cichnie       -> written@ = 0
4. WRACA A              -> attach=0, ZAIMPORTOWANY, podciagniety do ..._22-42-49
5. A od razu ponownie   -> POMINIETY: "already holds ..."
```

Krok 4 to wada, ktorej juz nie ma. Krok 5 to optymalizacja, ktora zostala.
Nosniki maja **rozne** GUID-y -- to czyni zapis faktem o nosniku, nie o etykiecie.

Kontrola: wobec `a0ed00d` suita daje 98/11, a wsrod czerwonych jest `L2: A
ROTATED MEDIUM BEHIND THE FAMILY IS IMPORTED, NOT SKIPPED`.

Ryzyko szczatkowe: zapis lezy poza nosnikiem, wiec host, ktory straci `/var/lib`,
zapomina, co ktory dysk trzyma. Jest to bezpieczne z konstrukcji -- brak zapisu
znaczy import -- ale pierwszy bieg po takiej stracie otworzy okno raz na kazdy
nosnik.

## MODEL REPLIKI: RAZ NA DOBE, OPCJONALNIE PO WLOZENIU (2026-08-29)

Decyzja wlasciciela po labie wyrwania: replika **nie jest lustrem online**.
Harmonogram raz na dobe, w nocy, po dziennym tierze -- albo od razu po podlaczeniu
dysku. Po skonczonej operacji pula sie eksportuje i dysk jest w stanie
bezpiecznego odlaczenia.

Uzasadnienie jest to samo, ktore wyszlo z pomiarow: nosnikowi mozna zaszkodzic
**wylacznie wtedy, gdy jego pula jest zaimportowana**, wiec liczba biegow JEST
ekspozycja. Godzinowa replika wystawiala dysk 24 razy na dobe bez powodu.

### Co sie zmienilo

| | |
|---|---|
| domyslny harmonogram `add-replica` | `30 2 * * *` zamiast godzinowego. Dzienny tier wysyla o 01:11 w dostarczanych profilach (00:11 w `prod`), wiec 02:30 jest po nim i wciaz w nocy |
| generator | **mowi**, gdy harmonogram repliki chodzi czesciej niz raz na dobe, z kosztem. Nie odmawia -- replika na dysk staly moze tego chciec, i to decyzja admina z cena przed oczami |
| drugi wyzwalacz | `install-media-trigger` -- regula udev uruchamiajaca `run-replicas`, gdy pojawi sie dysk z etykieta ZFS |

### Wyzwalacz po wlozeniu jest OPCJONALNY

Wyrazne polecenie wlasciciela: ma byc opcjonalny, a nie domyslny razem z tym z
harmonogramu. `add-replica` **nigdy** nie dotyka udev, a host, ktory chce tylko
nocnego biegu, po prostu nigdy nie uruchamia tego czasownika. Sa niezalezne:
zadne nie instaluje, nie implikuje ani nie wymaga drugiego. `remove-media-trigger`
cofa zgode -- usuwa wylacznie plik napisany przez to narzedzie i nie rusza crona.

Oba naraz nic nie kosztuja: dysk wlozony wieczorem robi swoj bieg, a nocny bieg
znajduje potem zero zapisanych bajtow i **w ogole nie importuje nosnika**.

Regula udev uzywa `systemd-run --no-block` i to nie jest opcja: udev serializuje
zdarzenia urzadzen, wiec regula czekajaca na backup zatrzymalaby kazde inne
zdarzenie na maszynie na czas transferu.

Dowiedzione na pve9: `udevadm trigger` uruchomil jednostke
`zfs-replica-insert-sdd1`, ta wykonala `run-replicas` i zakonczyla sie czysto.

### `sync=always` -- ROZSTRZYGNIETE: NIE DOTYCZY TRANSFERU

Domysl wlasciciela byl sensowny i wart sprawdzenia: inna polityka `sync`
skrocilaby okno, w ktorym dane wygladajace na zapisane nie sa jeszcze na
nosniku. **Nie skroci, bo nie dotyczy tej sciezki.**

Dwa pierwsze podejscia byly bezwartosciowe i tak je opisalem: czasy transferu pod
`standard` i `always` nie roznily sie, a `always` wychodzil nawet SZYBCIEJ, co
jest fizycznie bez sensu -- czyli pomiar nie mierzyl pokretla. Rozstrzygnela
dopiero KONTROLA, ktora nie jest transferem, na nosniku zdlawionym przez
hipervizor do 35 MB/s i 110 IOPS zapisu (mniej wiecej talerzowy USB):

```
zwykly zapis 64 MB    sync=standard   2.4 s
zwykly zapis 64 MB    sync=always     5.5 s     <- pokretlo DZIALA, kosztuje 2,3x
zapis oflag=dsync     sync=standard   5.6 s
zapis oflag=dsync     sync=always     5.6 s     <- juz synchroniczny, bez zmian
```

Skoro pokretlo dziala i kosztuje 2,3x na zwyklym zapisie, a czasy TRANSFERU sie
nie ruszaja, to `zfs receive` go nie honoruje -- jego zapisy ida prosto do grup
transakcji, z pominieciem ZIL.

**Wniosek: `sync=always` na datasecie repliki nie skroci okna transferu ani o
sekunde, a ukarze kazdy inny zapis do tego datasetu 2,3-krotnie. Nie
przyjmujemy.** To odpowiedz rozstrzygnieta, nie „nie dalo sie zmierzyc".

Nosnik `usbrep3` zostaje zdlawiony w konfiguracji VM -- lab jest przez to
blizszy prawdziwemu dyskowi USB niz byl.

### `sync=always` -- pierwszy, nierozstrzygniety pomiar (zachowany)

200 MB na nosnik, cztery biegi na przemian:

```
standard  21.9 s      always  19.6 s
standard  15.3 s      always  20.0 s
```

**Rozrzut wewnatrz trybu `standard` (21,9 vs 15,3) jest wiekszy niz roznica
miedzy trybami.** Pomiar tonie w szumie i nie pokazuje kosztu -- ale nie pokazuje
tez korzysci, a stanowisko badawcze jest tu najmniej reprezentatywne z mozliwych:
dysk wirtualny na szybkiej puli hosta, czyli dokladnie ten przypadek, w ktorym ZIL
nic nie kosztuje. Na prawdziwym talerzowym USB to samo pokretlo boli najbardziej.

Nie wiadomo tez, czy `zfs receive` w ogole honoruje `sync` -- dokumentacja mowi
"kazdy zapis przez ZIL", ale sciezka recv jest osobna i nie znalazlem
rozstrzygniecia.

**Wniosek: nie wlaczam tego domyslnie.** Warunek wlasciciela byl jasny -- jesli
transfer oberwie, nie chcemy tego -- a ja nie mam liczby, ktora by pokazala, ze
nie oberwie tam, gdzie to naprawde dziala.

## LAB: WYRWANIE NOSNIKA -- ZDIAGNOZOWANE (pve9, 2026-08-29)

Wlasciciel: fizycznego wypiecia nie da sie sprawdzic na VM, ale da sie je dobrze
zasymulowac, jesli dyski sa wypinalne komendami Linuksa. Sa:
`echo 1 > /sys/block/sdX/device/delete` wyjmuje urzadzenie spod dzialajacego
jadra bez unmounta, bez eksportu i bez ostrzezenia -- blizej szarpniecia kabla
niz odpiecie na hipervizorze, ktore jest uporzadkowanym usunieciem urzadzenia.

### Trzy pomiary

| kiedy wyrwano | skutek |
|---|---|
| miedzy biegami, pula wyeksportowana | bez szkody |
| przy puli zaimportowanej, bezczynnej | `zpool export` w nieprzerywalnym snie **11 minut** i dalej; nie da sie zabic; ponowne wpiecie NIE pomaga, bo jadro nadaje wracajacemu dyskowi NOWY wezel |
| **w trakcie zapisu 300 MB** | caly HOST przestal odpowiadac, konieczny twardy reset |

### Dlaczego -- to arytmetyka, nie kruchosc ZFS-a

Na tym hoscie: `zfs_txg_timeout` = 5 s, `zfs_dirty_data_max` = **393 MB**
(10% z 3927 MB RAM). Transfer mial 300 MB, wiec **miescil sie w calosci w oknie
brudnych danych** -- w chwili wyrwania praktycznie caly ladunek wisial w RAM i
nie mial dokad pojsc. Przy 10 MB (pierwszy pomiar) dane byly juz zapisane i
zawisl wylacznie eksport.

Czego pomiary NIE pokazaly, i nie bede tego twierdzil: silnik **nie zglosil
falszywego sukcesu**. W pierwszym tescie transfer naprawde zdazyl sie skonczyc
przed wyrwaniem (snapshoty `yank_` sa na nosniku); w drugim nie zdazyl nic
zglosic, bo host padl pod nim.

### Co z tego wynika dla pakietu

Drugi wiersz tabeli to problem PAKIETU, nie ZFS-a: `detach` stoi **poza** klamra
`if`, wiec zadanie crona, ktore na to trafi, **wisi na zawsze** -- trzyma swoj
flock, kazdy nastepny bieg tego zadania jest odrzucany jako sporny, i nic nie
alarmuje, bo zadanie, ktore nigdy nie konczy, nigdy nie raportuje statusu. Cicha,
trwala smierc zadania backupu.

Dwa zabezpieczenia, oba w bramce:

- **eksport ograniczony czasem** (`MEDIA_EXPORT_TIMEOUT`, domyslnie 90 s). Timeout
  nie naprawia wejscia/wyjscia -- nie moze -- ale zamienia nieprzerywalna cisze w
  glosna, niezerowa odpowiedz, ktora nazywa dysk i mowi, zeby go nie wyjmowac;
- **ostrzezenie o `failmode=wait`** przy imporcie. ZFS domyslnie czeka, co jest
  wlasciwe dla dysku, ktory nigdzie sie nie wybiera, i niewlasciwe dla takiego,
  ktorego sensem jest bycie wyjmowanym. **Ostrzezone, nie zmienione**: failmode to
  wlasnosc puli admina, a ciche przepisanie tego, jak cudze dane zachowuja sie
  pod awaria, nie jest decyzja tego narzedzia.

Sekcja J suity `mediagate` pilnuje obu; kontrola: wersja z `main` wywraca szesc
asercji.

### Czy to wyklucza uzycie repliki -- odpowiedz po przeszukaniu zrodel

Wlasciciel: smierc hosta i wieczny hang praktycznie wykluczaja takie korzystanie
z repliki. Sprawdzone u zrodla, nie zgadniete.

To jest **znana, nierozwiazana slabosc OpenZFS**, nie wada tego pakietu:
- `failmode=wait` (domyslne) przy zawieszonej puli **wyglada dokladnie jak
  zawieszenie** -- polecenia dotykajace puli blokuja sie na zawsze i sa
  nieprzerywalne (dokumentacja OpenZFS mowi to wprost);
- `failmode=continue` zwraca EIO nowym zapisom, ale **niezatwierdzone zapisy
  pozostaja zablokowane** -- i to pokrywa sie z moim pomiarem: host padl mimo
  `continue`;
- openzfs/zfs #14032 „Need to fail more gracefully after surprise (USB) drive
  removal", #7990, #14651 -- otwarte zgloszenia o dokladnie tym zachowaniu.

**Rada spolecznosci jest wszedzie ta sama: eksportuj PRZED wyjeciem.** Wzorzec z
forum Proxmoxa dla dyskow rotacyjnych to skrypt, ktory importuje przy podlaczeniu
i eksportuje przed odlaczeniem -- czyli dokladnie ta klamra, ktora juz mamy.

**Trzeci pomiar, ktorego wczesniej nie zrobilem:** udokumentowana sciezka wyjscia
(przywroc urzadzenie, `zpool clear`) **sama polozyla hosta**. Rescan magistrali
przy puli trzymajacej znikniety vdev zabil sesje i wymusil reset. Wczesniej
napisalem „tylko reboot" nie sprawdziwszy `zpool clear` -- klasyfikator go
zablokowal i poszedlem na skrot. Sprawdzone: do `zpool clear` nie da sie dojsc,
bo host pada wczesniej.

### Wniosek i co z tego robimy

ZFS na nosniku wymiennym jest bezpieczny **wylacznie wtedy, gdy dysk nie jest
wyjmowany przy zaimportowanej puli**. Zadne ustawienie tego nie zmienia. Wiec
okno da sie tylko **skrocic, uwidocznic i uglosnic**:

| | |
|---|---|
| skrocic | klamra importuje pule tylko na czas biegu -- a od 2026-08-29 **w ogole nie importuje, gdy nie ma czego wyslac**: `attach --source DS --prefix P` pyta na ZRODLE, czy cokolwiek zapisano od ostatniego snapshotu rodziny repliki (`written@`), i przy zerze zostawia nosnik w spokoju. Na spokojnym zrodle dysk przestaje byc wystawiany co godzine bez powodu |
| uwidocznic | `status` mowi teraz wprost **SAFE TO UNPLUG** albo **DO NOT UNPLUG** wraz z kosztem |
| uglosnic | eksport ograniczony czasem zamiast nieskonczonego wisenia; ostrzezenie o `failmode=wait` |

Sonda `written@` **opoznia sie o grupe transakcji** (`zfs_txg_timeout`, 5 s) --
zmierzone ponownie przy dowodzeniu tego mechanizmu. Przyjete swiadomie: najgorsze,
co moze kosztowac, to JEDEN pominiety bieg przy harmonogramie godzinowym, dane nie
gina, a nastepny bieg je zabiera. Wymuszanie `sync` dla swiezszej liczby oznaczaloby,
ze ta kontrola pisze do puli, ktorej ma nie dotykac.

Ryzyko szczatkowe: ktos wyciaga dysk dokladnie w trakcie biegu. To blad
operatora tej samej klasy co wyrwanie dowolnego dysku zewnetrznego w trakcie
zapisu -- z ta roznica, ze ZFS karze za to ostrzej niz ext4.

**Alternatywa architektoniczna, gdyby odpornosc na wyrwanie byla wazniejsza niz
ZFS na nosniku:** zwykly system plikow na dysku wymiennym i strumienie
`zfs send` zapisywane jako pliki. Wyrwany ext4 da sie naprawic, wyrwana pula ZFS
klinuje jadro. Koszt jest realny i nie zamierzam go ukrywac: strumien jest
nieprzezroczysty (`zfs list` na kopii nie dziala), a **uszkodzony strumien jest
nie do odzyskania w calosci** -- to znany argument przeciwko trzymaniu backupow
w tej postaci. Decyzja wlasciciela, nie moja.

### Otwarte

Polityka `sync`/buforowania dla nosnikow wymiennych -- hipoteza wlasciciela, ze
inne ustawienia zmniejszylyby okno. `sync=always` na datasecie repliki jest
kandydatem: skraca okno, w ktorym dane wygladajace na zapisane nie sa jeszcze na
nosniku. Koszt przepustowosci NIEZMIERZONY, wiec nie rekomenduje tego jako
domyslnego, dopoki nie bedzie liczby.

## LAB: moveclient-live -- WYKONANY (pve9 + pve9b, 2026-08-29)

Obowiazek reczny `moveclient-live` zamkniety. Wymagal DRUGIEJ maszyny: silnik
odmawia transferu, gdy `machine-id` obu stron sa identyczne (`CRITICAL: identical
machine-id ... loopback transfer attempt`), wiec jedna VM nie mogla tego zrobic
sama ze soba. Bliznik pve9b to VM 110 na pve2 -- klon 109 z **przegenerowanym**
`machine-id`, zdjetymi dyskami wymiennymi i wyczyszczonym panstwem po pve9.

Pelna, prawdziwa relacja: `add-client` -> `deploy.sh --join` (zakres zawezony do
jednego datasetu) -> `seed` przez siec -> `activate`. Dopiero na tym `move-to-client`
ma co przenosic.

### Kryterium 3 REV-123 F1 -- dowod bajtowy

Wstrzykniecie to stub `mv` na PATH, ktory zawodzi **wylacznie** przy
przemianowaniu, ktorego celem jest rekord klienta. To trafia dokladnie w moment,
o ktory chodzi: config i oba crontaby sa juz zainstalowane (log pokazuje
`crontab updated`, a zaraz po nim wycofanie).

| wariant | co pada | wynik |
|---|---|---|
| 1 | PIERWSZE przemianowanie | rc=1; config, oba rekordy, crontab i stan pauzy bajt w bajt |
| 2 | pierwsze przechodzi, **DRUGIE** pada | rc=1; to samo -- wycofanie cofnelo takze to, co juz zapisalo |
| kontrola pozytywna | nic nie pada | ruch przechodzi i zmienia wszystkie trzy pliki |

Kontrola pozytywna jest tu warunkiem, nie ozdoba: bez niej „nic sie nie zmienilo"
moglo znaczyc, ze czasownik nigdy nie dotarl do publikacji.

### Wada znaleziona przez ten lab

Lab uruchomil czasownik DWA razy i dopiero to ja pokazalo. `move-to-client`
pauzuje ZRODLO i nigdy nie pyta o CEL. Przenies A na B, a pozniej B z powrotem na
A -- i A jest wciaz zapauzowane z pierwszego ruchu. Bierze sekcje, crontab sie
instaluje, czasownik pisze `'alfa' carries the schedule`, a kazde zadanie z
`-L alfa` konczy sie SKIPPED, bo pauza jest wlasnoscia etykiety, ktora wlasnie
dostaly. Zmierzone: `snapget` odpowiedzial
`SKIPPED: relationship alfa is paused` na linii, ktora przekazanie dopiero co
zainstalowalo. **Falszywe zdrowie oglaszane jako sukces.**

Odmowa, nie ciche wznowienie: zapauzowany cel to NORMALNY stan w trakcie
odtwarzania na niego, wiec zdjecie pauzy samo z siebie byloby narzedziem
unieważniającym transakcję, ktora admin otworzyl. Komunikat nazywa polecenie,
ktore ja konczy.

`RELATIONSHIPS_DIR` jest teraz nadpisywalny w tej samej formie co `CLIENTS_DIR` --
nie nowa mozliwosc, tylko warunek testowalnosci: bez tego odmowa czytajaca ten
katalog nie dala sie sterowac z suity.

## REPLIKI Z WYSOKIEGO POZIOMU (2026-08-29)

Polecenie wlasciciela: ma byc konfigurowalne z gory, **bo docelowo idzie w GUI**.
To nie jest prosba o wygode, tylko ograniczenie ksztaltu -- formularz nie edytuje
pliku INI i nie da sie mu kazac wkleic `zpool create`.

| czasownik | co robi |
|---|---|
| `add-replica NAZWA --source= [--source= ...] --dst= [...]` | **upsert** sekcji `[replica:]`; domyslnie PLAN, `--install` podmienia config i crontab razem |
| `list-replicas [--json]` | inwentarz + zywy stan nosnika |
| `remove-replica NAZWA [--install] [--yes]` | zdejmuje zadanie; **kopii na nosniku nie rusza** |

`--json` idzie ta sama konwencja co `progress --json`, ktore juz jest w tym
projekcie zadeklarowane jako warstwa danych pod GUI. Od 2026-08-30 niesie tez
`"sources"` jako TABLICE obok surowego `"source"`, zeby front nie parsowal
gramatyki configu.

### Trzy wady znalezione przy rozbiorce labu (2026-08-30)

Wszystkie trzy lezaly na drodze, ktora GUI musi przejsc.

**Nie dalo sie usunac OSTATNIEJ repliki.** Config mial trzy, dwie zeszly,
trzecia padla na `no send/prune/monitor rules resolved` -- i zadanie zostalo w
harmonogramie, wskazujac na skasowany dataset. Ta straz jest sluszna, gdy ktos
podaje generatorowi oprozniony config, i bledna jako odpowiedz na „usun ostatnie
zadanie", gdzie pustka JEST wynikiem. `remove-client` rozwiazal to samo dawno
temu, wiec `remove-replica` uzywa jego odpowiedzi: najpierw `cron_block_remove`,
potem podmiana configu -- w tej kolejnosci, bo odwrotna zostawia config
opisujacy zero zadan przy zywych liniach crona.

**`--yes` dzialalo, ale nie bylo w pomocy.** `--install` czytalo `/dev/tty`,
czego nie wysteruje ani cron, ani `ssh -T`, ani front.

**Replika niosla tylko JEDEN dataset**, a druga sekcja `[replica:]` na ten sam
dysk jest odmawiana z dobrego powodu (dwa zadania dzielace pule eksportuja ja
sobie spod rak w trakcie zapisu). Teraz `--source` jest powtarzalne, pole
`source` jest lista, a N wywolan silnika idzie w **JEDNA** klamre
import/eksport: oknem jest ekspozycja, wiec klamra na kazde zrodlo osobno
otwieralaby N okien, nie oszczedzajac nic.

Zlozony status to **pierwszy niezerowy wygrywa** -- `m` trafia do
`detach --engine-rc`, a zero tam przesuwa zapis mowiacy, ze ten nosnik jest
aktualny. Jeden dataset, ktory sie nie skopiowal, to jeden dataset, dla ktorego
nosnik aktualny NIE jest.

Szybka sciezka bramki stala sie przez to koniunkcja: zrodla rozjezdzaja sie
niezaleznie, wiec nosnik bywa aktualny dla jednego i tydzien do tylu dla
drugiego. Pominiecie wymaga, by KAZDE zrodlo bylo ciche i KAZDE udowodnione na
tym GUID-zie; zapis trzyma jedna linie na dataset, bo pojedyncze `snap=` moglo
opisac tylko jedno z nich.

Ksztalt linii dla jednego zrodla zostal **bajt w bajt** taki, jaki nosza
wdrozone hosty. Lista to nowa mozliwosc, nie powod do przepisania istniejacych
linii. `cron2conf.sh` czyta oba ksztalty z powrotem.

### ROZRZUT OMIJAL JEDYNE ZADANIE, KTORE NAPRAWDE WALCZY O LACZE (2026-08-30)

Pytanie wlasciciela: „to juz przecial dzialalo, jaki jest z tym problem?".
Odpowiedz: dzialalo i dziala -- ale nigdy nie objelo tego zadania.

`63f69eb` rozrzucil relacje po zegarze, a jego wlasny pomiar nazwal koszt:
*„all at :01 and all pruning at :21 ... a thundering herd on the link, the
source's disks and sshd"*. Dostaly minute: wysylka i przycinanie **lokalne**.
`append_source_prune_create` -- jedyna sekcja otwierajaca sesje SSH do hosta
zrodlowego, czyli jedyna dotykajaca WSZYSTKICH trzech rzeczy z tamtego zdania --
nie zostala w tym commicie tknieta ani razu (`git show 63f69eb | grep -c
append_source_prune_create` = 0). Luka jest wiec dokladnie odwrocona wzgledem
intencji.

Zmierzone na labie, dwie relacje: wysylki :57 i :01, przycinania lokalne :17 i
:21, i **oba** przycinania zrodel na :21 razem z lokalnym -- trzy zadania, dwa z
nich po SSH do roznych hostow, w jednej minucie. Odtworzylo sie identycznie po
odbudowie, wiec jest deterministyczne, nie przypadkowe.

Zmierzony skutek przy DWOCH zrodlach: cztery zadania odpalone w tej samej
chwili ruszyly w ciagu 4 ms, bieglo **rownolegle** (501/535/1772/1815 ms),
wszystkie `rc=0`. Przy tej skali nie boli; przy dziesieciu to dziesiec
jednoczesnych sesji SSH.

**Naprawa: trzeci slot.** `+40` zachowuje 20-minutowy odstep, ktory profil mial
miedzy wysylka a przycinaniem, i stawia to kolejne 20 od obu -- trzy rowno
rozlozone minuty na relacje zamiast dwoch i kupki. Wyrazenie jest PRZEKAZYWANE
z miejsca, gdzie minuta juz jest policzona, nie liczone drugi raz:
`schedule_pick_minute` czyta zainstalowany crontab i po zainstalowaniu linii
wysylki odpowiedzialoby inaczej.

Puste wyrazenie znaczy „dziedzicz z szablonu" -- czyli to, co robi kazda sekcja
zapisana wczesniej. Emiter piszacy minute zawsze przesunalby zadania na hostach,
ktore o to nie prosily; kontrola w suicie pilnuje wlasnie tego.

Suita `stagger` miala dwadziescia przypadkow i **ani jednego** patrzacego na
przycinanie zrodla. Teraz 26/0, 25/1 bez linii emitujacej.

Pierwsze podejscie do tej naprawy **zepsulo emisje sekcji** i CI powiedzialo to
w najuczciwszy mozliwy sposob -- padnieciem KONTROLI (`96x control: a readable
fragment still produces the source prune section`).
`emit_remote_source_prune` konczy sie **zmienna lista datasetow**, wiec czwarty
argument pozycyjny przed ta lista zjada pierwszy DATASET: lista wychodzi pusta,
`[ "$#" -gt 0 ] || return 0` odpala i sekcja nie powstaje w ogole. Poprawione
tak, zeby ten blad byl niemozliwy, a nie tylko cofniety: `--schedule=EXPR`,
parsowane po argumentach stalych. Nazwa datasetu nigdy tak nie wyglada, a
wywolanie bez flagi zachowuje sie jak dotad.

### NOSNIK Z CUDZA LINIA JEST ODMAWIANY, TYMI SLOWAMI (2026-08-30)

Znalezione przez CZYSTY PRZELOT: rozbiorka labu do zera i odbudowa od nowa.
Dysk wciaz niosl replike relacji, ktora wlasnie zostala zdjeta, a odbudowane
datasety kolektora dostaly **nowa rodzine snapshotow bez wspolnego przodka**.
Silnik nie moze ani wyslac przyrostu (brak wspolnego snapshotu), ani zasiac od
nowa (cel ma snapshoty), wiec operator dostawal co noc:

```
cannot receive new filesystem stream: destination has snapshots
(eg. ...@replica_2026-08-30_11-18-29) must destroy them to overwrite it
```

Prawda, o ZFS-ie, i milczaca o decyzji, ktora stoi przed czlowiekiem.

**Zachowanie pakietu bylo poprawne** -- ZFS nie ma prawa nadpisac cudzych
snapshotow. Wada byla DIAGNOZA. Bramka sprawdza teraz przy `attach`, czy cel na
nosniku dzieli ze zrodlem **jakikolwiek** snapshot rodziny; gdy nie dzieli
zadnego, odmawia z `rc=2`, nazywa obie rodziny, stawia wybor (inny `--dst` albo
`zfs destroy -r <cel>`) i **eksportuje pule z powrotem**, zeby odmowa nie
zostawila uzbrojonego zawieszenia, ktoremu ma zapobiegac.

Tylko przy ZERO wspolnych snapshotow. Cel dzielacy cokolwiek to zwykly przyrost
i nie wolno go ruszac -- kontrola N2 istnieje wlasnie po to.

mediagate 134/0, 126/8 z odwroconym warunkiem.

### WARSTWA POMIAROWA JEST KOMPLETNA -- dwa moje bledne zgloszenia (2026-08-30)

Zglosilem wlascicielowi dwie luki, ktorych nie ma. Obie sa tu opisane, bo
wersja z lukami zdazyla trafic do jego decyzji.

**Objetosci i przepustowosc SA zapisywane.** Czytalem 119 rekordow `progress`,
naliczylem `wire_bytes > 0` w zerze przypadkow i `rate_bps > 0` w zerze, i
uznalem, ze pola sa w schemacie, ale nikt ich nie wypelnia.
`progress_watch` tyka **co 2 sekundy**, a kazdy transfer w mojej probie trwal
0-1 s i niosl kilka MB. Jeden bieg na 600 MB rozstrzygnal:

```
total_bytes = 630279464   done_bytes = 551425752
wire_bytes  = 617611264   rate_bps   = 116537608   (6 s)
```

Dwa podsekundowe datasety w TYM SAMYM biegu zostaly na zerach, dokladnie jak z
projektu wynika. `done_bytes` to co silnik wepchnal w rure, `wire_bytes` to co
wyszlo z hosta -- roznica jest kompresja; `-1` znaczy "niemierzalne tutaj"
(push trzyma swoj mbuffer po STRONIE ZDALNEJ), nigdy 0, zeby brak pomiaru nie
czytal sie jako bezczynne lacze.

**Rekordy SA sprzatane.** `progress_reap()` jest wolana przez OBA silniki przy
kazdym biegu, trzyma 7 dni i pomija rekordy w stanie `running`. Najstarszy
rekord na hoscie mial rowno siedem dni -- to byl dzialajacy sprzatacz, ktory
przeczytalem jako jego brak, bo grepowalem slowa, ktorych sie spodziewalem
(`clean`, `prune`, `rm -f`), zamiast rzeczy (`progress_`).

Zapisane w bledniku jako **E24, pod R6**: zero, pusty grep i brakujace pole to
tez odczyty, a odczyt jest dowodem tylko wobec kontroli, ktora dalaby wynik
przeciwny.

**Co z tego zostaje dla GUI:** warstwa danych jest gotowa i nie wymaga zmian.
`ZFS-JOB BEGIN/END` daje czas i `rc` per zadanie z pelna historia, a
`progress --json` daje per dataset tryb, czas, objetosc i przepustowosc -- dla
transferow dluzszych niz tick, czyli dla wszystkich, ktore w GUI kogokolwiek
zainteresuja.

### `--commit-scope` I `--leave` -- DYSPOZYTORY PRZENIESIONE (2026-08-30)

`deploy.sh --commit-scope=LABEL` byl **martwy na main**. Zmierzone na pve2,
hoscie produkcyjnym:

```
./deploy.sh --commit-scope=nieistnieje
./deploy.sh: line 3388: do_commit_scope: command not found
```

bash definiuje funkcje w miare czytania, a ta stala w ~5900 -- **za**
dyspozytorem. Przeniesienie z 2026-08-26 przed Faze 1 bylo sluszne co do
intencji (odpowiadanie na pytanie o uprawnienia nie ma prawa ciagnac repo i
przepisywac crona), ale zamienilo "provisionuje, gdy nie powinien" na "nie
uruchamia sie wcale". Nikt tego nie zlapal, bo `--join` dochodzi do tej samej
funkcji z wlasnego dyspozytora u stopy pliku, wiec kazde wdrozenie dzialalo.

`--leave` mial druga polowe tego samego problemu: wywolywany za wszystkimi
siedmioma fazami, wiec **ciagnal repo na maszynie, ktora sie rozbiera**, a
checkout stojacy na galezi nie dawal sie opuscic w ogole (`fatal: Not possible
to fast-forward`). Dotyczylo to takze `remove-client`, ktory siega po `--unpair`
ta sama droga.

**Naprawa.** Domkniecie policzone, nie zgadniete: 25 funkcji, z czego 8 ponizej
dyspozytora, przeniesione ponad niego razem z jedyna globalna, ktora czytaja --
`COMMIT_SCOPE_HOLD_TAG`, decydujaca o tym, czy dataset jest trzymany, zanim
odbierze mu sie nadanie. Nazwy `PEER_JOIN_*`, ktore wygladaly na globalne,
okazaly sie liniami heredoca zapisujacego manifest.

Oba czasowniki koncza teraz przed Faza 1. Test w suicie `pairgate` pilnuje, ze
**docieraja do swoich funkcji** (`command not found` to dokladnie to, co ma byc
niemozliwe) i ze **nie provisionuja hosta po drodze** -- z kontrola, ze zwykly
bieg nadal wchodzi w fazy, bo bez niej te asercje przeszlyby na buildzie, ktory
przestal provisionowac w ogole. Te przypadki byly NIEMOZLIWE do napisania przed
przeniesieniem -- sandbox nie przechodzil Fazy 1 -- i wlasnie dlatego nic nie
pilnowalo tej regresji.

pairgate 83/0, 80/3 bez przeniesienia.

### `--leave` ZOSTAWIAL KATALOG BRAMKI GRUPY SKASOWANEGO KONTA (2026-08-30)

Naprawione. `deploy.sh --leave` pisal „'pve9' fully torn down on this host", a
`clean-relationships.sh` sekunde pozniej nazywal ta sama etykiete ORPHAN --
pakiet przeczacy sobie o jedno polecenie. Zdarzylo sie na pve1 **i** pve2.

Halas byl mniejsza czescia. Katalog nalezy do grupy konta, ktore `--leave`
wlasnie skasowal (zmierzone: `drwxrwsr-x`, grupa 1001, setgid), a nastepny
`--join` na tym hoscie dostal uid 1001 ponownie. Pozniejsza, niezwiazana
relacja dziedziczylaby zapis do katalogu bramki **cudzej** etykiety -- tego,
w ktorym lezy znacznik `disabled`, czyli granica twardego wylaczenia.

Usuwany tylko gdy PUSTY, i to nie jest ostroznosc: niepusty katalog trzyma zywy
stan tej etykiety (czyjes wylaczenie), a ciche skasowanie go zdjeloby blokade,
o ktorej zdjecie nikt nie prosil. Jest wiec nazywany. Obie galezie sprawdzone
na zywo na pve9.

### CALY ESTATE STAL NA 85-93% TWARDEGO LIMITU CRONA (2026-08-30)

Znalezione przez wdrozenie, nie przez suite. Druga replika nie dala sie
zainstalowac -- `crontab(1)` odmowil, a wywolujacy zglosil tylko rollback bez
przyczyny. Powodem bylo `command too long`: vixie-cron przyjmuje polecenie do
**1000 bajtow**.

Zmierzone na pve9, na ZWYKLYM wdrozeniu z dwoma relacjami:

| linia | znakow | zapas |
|---|---|---|
| backup `snapget` | 890 | 110 |
| backup `snapget` (druga relacja) | 889 | 111 |
| przycinanie zrodla, z flagami ssh | 846 | 154 |
| replika, JEDNO zrodlo | 934 | 66 |
| replika, DWA zrodla | 1160 | **odmowa** |

To nie byl problem repliki. Dluzsza nazwa hosta, glebsza sciezka datasetu albo
jedna flaga ssh wiecej i **zwykle zadanie backupu przestaje sie instalowac**.

#### Pierwsze podejscie bylo zlym interesem i zostalo cofniete

Skrocilem SCIEZKI, nazywajac je raz jako zmienne crontaba (`ZSA_REPO` i
rodzina). Kupilo 140 bajtow i kosztowalo wiecej: **linia skopiowana z crontaba
i uruchomiona z reki przestala dzialac** -- `$ZSA_LOG: ambiguous redirect`. A
to jest odruch admina przy diagnozie zadania. Wlasciciel odrzucil ten
kompromis; pomiar przyznaje mu racje.

#### Wlasciwe miejsce to KOPERTA, nie sciezki

| | znakow |
|---|---|
| linia ze zmiennymi | 901 |
| ta sama ze sciezkami wprost | 1051 -- ponad limit |
| **sama koperta** (echo BEGIN/END, mktemp, cat, notify, sprzatanie) | **336** |

Koperta to jedna trzecia kazdej linii, powtarzana w KAZDYM zadaniu. Przeniesiona
do `zfs-job.sh`:

```
30 2 * * * /sciezka/zfs-job.sh "pve9 replica copy (weekly)"              --log=... --notify=... --detail=8 -- <polecenie silnika>
```

**Polecenie silnika zostaje widoczne w crontabie**, linia jest samowystarczalna
(skopiuj i uruchom -- zachowa sie jak pod cronem), a `cron2conf.sh` dalej czyta
z niej wywolanie silnika. Replika dwuzrodlowa: **796 znakow**. Zmienne `ZSA_*`
usuniete z generatora; `cron2conf.sh` **czyta je nadal**, bo hosty zainstalowane
w tym krotkim oknie maja je do najblizszej reinstalacji.

Klamra nosnika to skladnia powloki, nie polecenie z argumentami, wiec jedzie
przez `sh -c` jako JEDEN argument -- tak samo, jak cron traktowal cala linie
wczesniej. Cudzyslow pojedynczy, i **odmowa zamiast kalectwa**, gdyby kiedys
trafil tam apostrof: kazda wartosc jest walidowana do `[A-Za-z0-9._:/-]`, a
"nie moze wystapic, bo gdzies indziej jest kontrola" to dokladnie to
rozumowanie, ktore ma glosno paść, gdy przestanie byc prawdziwe.

`cron_write` **diagnozuje** odmowe zamiast ja przekazywac: po niepowodzeniu
nazywa kazde polecenie powyzej 1000 bajtow z jego dlugoscia. Diagnoza PO
awarii, nigdy bramka przed nia -- wlasny limit zmyslony przed czasem odrzucalby
linie, ktore inny cron by przyjal.

#### I drugi raz to samo: bit wykonywalnosci

`zfs-job.sh` poszedl na main jako **100644**. Wdrozyl sie na cztery wydania
jako `-rw-r--r--`, a wygenerowana linia crona wywoluje go BEZPOSREDNIO -- kazde
zarzadzane zadanie na kazdym hoscie padloby na `Permission denied`. Nie jedno
zadanie: wszystkie, bo koperta jest wspoldzielona.

Ten box to Git Bash na Windowsie: drzewo robocze nie niesie bitu do zapisania,
wiec `chmod +x` przed `git add` nie zmienia niczego w indeksie, a `test -x`
lokalnie przechodzi. Trzeba `git update-index --chmod=+x`.

**Projekt juz to wiedzial** -- `impact.sh` ma kontrole "declared suites exist
and are executable", ktorej komentarz opisuje dokladnie ten mechanizm. Byla
zastosowana tylko do SUIT. Rozszerzona teraz na wdrazane skrypty, z regula
"shebang plus nie `lib-*.sh` znaczy 100755", i **od razu zlapala zastany
przypadek**: `zfs-restore.sh` mial 100644. Dzis dziala, bo `zfs-backup.sh` wola
go przez `exec bash`, ale plik z shebangiem deklaruje, ze ma byc uruchamiany
wprost, i pierwsze takie wywolanie by go wywrocilo.

#### Przy okazji: `.gitignore` odmowil dodania nowego skryptu

`.gitignore` jest lista dozwolonych. `git add zfs-job.sh` zostal odrzucony, a
sprawdzenie systematyczne pokazalo **trzy dalsze pliki** w tym samym stanie --
`zfs-media-gate.sh`, `lib-cron.sh`, `lib-scope.sh` -- sledzone wylacznie
dlatego, ze git juz o nich wiedzial. Plik sam dokumentuje, ze ta pulapka ugryzla
juz dwa razy (`deploy.sh`, `profiles/`). Poniewaz wdrozenie to godzinowy `git
pull`, skrypt ktory nie trafi do repozytorium to **kazda linia crona na kazdym
hoscie padajaca naraz**. Wszystkie cztery dopisane, z jednolinijkowym testem w
komentarzu.

cron 132/0, golden 96/0, cron2conf 28/0, mediagate 134/0, stagger 26/0,
cleanrel 87/0, pairgate 78/0.

### Audyt relacji mowil ALREADY GONE o zywych danych (2026-08-30)

Ta sama rozbiorka, inne narzedzie. `clean-relationships.sh` na pve1 wypisal:

```
data  hdd/labsrc hdd/labsrc/vm-900-disk-0 hdd/labsrc/vm-900-disk-1  (ALREADY GONE)
```

Wszystkie trzy istnialy. Rekord po stronie ZRODLA nie jest `%q`-cytowany tak jak
kolektora: `PEER_JOIN_GRANTED_DATASETS="a b c"` -- w cudzyslowie, przez GOLE
spacje. Rozdzielacz znal `\ ` i przecinek, wiec trzy nazwy poszly do `zfs list`
jako jedna i wrocily jako nieobecne.

Kierunek awarii jest tym zlym: to jest raport, na ktorym czlowiek sprzatajacy
hosta podejmuje decyzje, powiedzial mu ze danych juz nie ma, a purge czyta to
samo pole. Wlasny komentarz pliku od dawna stwierdzal, ze legalna nazwa ZFS nie
moze zawierac spacji -- wniosek, ze gola spacja ZAWSZE jest rozdzielaczem, nigdy
nie zostal wyciagniety.

### Cztery stany nosnika, nie dwa

Bramka odpowiada „czy pula jest zaimportowana" -- wlasciwe pytanie dla zadania,
ktore zaraz bedzie pisac, i **niewlasciwe dla czlowieka patrzacego na liste**:
dysk lezacy w kieszeni z wyeksportowana pula czytalby sie jako `away`, czyli jak
dysk w sejfie. Listowanie rozroznia `here` / `available` / `away` /
`wrong_medium`, i robi to **poza** bramka, zeby nie ruszac kontraktu kodow
wyjscia, na ktorym stoja linie crona.

### Odmowy, ktore znalazl wlasny lab

Pozwolilem wskazac ten sam nosnik dwa razy -- najlatwiejszy blad do popelnienia w
formularzu. Skutek jest gorszy niz wyglada: znacznik wlasnosci bramki jest **per
etykieta**, wiec oba zadania uznalyby, ze zaimportowaly pule, i to, ktore
skonczy pierwsze, wyeksportowaloby ja spod drugiego W TRAKCIE ZAPISU. Odmawiane
w obie strony: ten sam `dst` i ta sama PULA pod inna etykieta.

### `history` -- ile luki jedzie, gdy wspolny snapshot przezyl

Pytanie wlasciciela: dla dysku nieobecnego kwartal ciagniecie wszystkich
snapshotow po drodze bywa bez sensu.

**W tym konkretnym przypadku pytanie jest bezprzedmiotowe** -- gdy retencja zjadla
wspolny snapshot, silnik spada na kotwice-bookmark, a bookmark nie niesie danych:
wysylka to jeden diff i inaczej byc nie moze. Pole gryzie tylko wtedy, gdy
wspolny snapshot PRZEZYL.

| wartosc | flaga | znaczenie |
|---|---|---|
| `all` (domyslne) | `-I` | kazdy snapshot po drodze |
| `newest` | `-i` | tylko roznica do najnowszego |
| `auto:N` | `-T N` | silnik decyduje, mierzac w WLASNYCH interwalach datasetu |

Bez domyslnej „inteligencji", bo dwa dyski tego samego wlasciciela chca czegos
przeciwnego: para tygodniowa niesie stan biezacy, a dysk kwartalny JEST archiwum.
Koszt powiedziany wprost w kodzie i w pomocy: przy `newest`/`auto` kopia dostaje
DZIURY -- snapshoty powstale miedzy wizytami nosnika nigdy tam nie trafia.

`history` i `flags` naraz to **odmowa**, nie regula pierwszenstwa: kto napisal
oba, mial na mysli jedno.

## LAB: TRZY REPLIKI NA DYSKACH WYMIENNYCH -- STOI (pve9, 2026-08-29)

Przestrzen labowa zbudowana na polecenie wlasciciela. pve9 to VM 109 na pve2;
dolozone trzy dyski wirtualne 2 GB z numerami seryjnych USB-A/USB-B/USB-C, wiec
maja stabilne sciezki w `/dev/disk/by-id` -- dokladnie jak prawdziwy dysk USB.
Weszly na goraco, bez restartu.

| nosnik | pula | rola |
|---|---|---|
| USB-A | `usbrep1` | tygodniowy, rotacja |
| USB-B | `usbrep2` | tygodniowy, rotacja |
| USB-C | `usbrep3` | kwartalny |

**Zrodlo repliki to prawdziwe kopie z INNEJ maszyny**, nie material syntetyczny:
`hdd/labcoll/192.168.28.9/hdd/labsrc/vm-900-disk-{0,1}` -- dwa wolumeny VM 900,
ktore pve1 (28.9) wysyla tu co godzine. W chwili labu 75 snapshotow, najstarszy
z 2026-08-29.

Konfiguracja to trzy sekcje `[replica:]` na jednym zrodle -- czego grammar do
dzisiaj nie umial wyrazic (`duplicate section [dataset:hdd/labcoll]`).

### Co zostalo dowiedzione, na prawdziwym urzadzeniu

| | teza | pomiar |
|---|---|---|
| 1 | bramka znajduje PRAWDZIWY dysk bez podpowiadania sciezki | `attach usbrep1` -> `imported`, bez `--dir`; tamta poprawka dotyczyla wylacznie puli plikowej |
| 2 | pelna klamra na wygenerowanej linii crona | trzy linie, kazda `rc=0`, pula wyeksportowana po transferze |
| 3 | caly zbior kopii z innej maszyny laduje na nosniku | `usbrep1/replica/hdd/labcoll/192.168.28.9/hdd/labsrc/vm-900-disk-{0,1}` |
| 4 | **wyjecie dysku nie jest bledem** | `qm set 109 --delete scsi2`; zadanie: `SKIPPED ... Nothing was run and nothing is wrong`, `rc=0`, zero maili |
| 5 | nieobecnosc jednego nie dotyka pozostalych | `usbrep2` przeszedl normalnie, gdy USB-A byl wyjety |
| 6 | **dysk wracajacy po utracie wspolnego punktu bierze INKREMENT** | patrz nizej |
| 7 | kazdy nosnik ma wlasna kotwice | trzy `#tgt-` na `hdd/labcoll`, po jednej na medium |

### Punkt 6 -- kryterium jest dysk, nie log

Skasowana na zrodle **cala** rodzina `replica_` -- czyli retencja odebrala
wspolny punkt wszystkim trzem replikom naraz. Zostaly same kotwice. Po ponownym
wpieciu USB-A i jednym przelocie:

```
snapshotow na kopii PRZED:  6
snapshotow na kopii PO:    12
kazdy stary snapshot wraz z GUID: NADAL OBECNY
```

Przesiew od zera musialby przyjsc z `recv -F`, ktory zmiotlby je co do jednego.
Nie zmiotl -- wiec byl inkrement, zakotwiczony w bookmarku. Generowana linia nie
niesie `-v`, wiec log tego NIE mowi; dowod jest wylacznie na dysku i tak ma byc.

### Wady znalezione przez ten lab

| | wada |
|---|---|
| R1 | grammar nie umial wyrazic dwoch replik jednego zrodla. Dodany typ sekcji `[replica:]` -- replika to inny RODZAJ zadania (bez monitora, bez prune zrodla, bez relacji), a nie drugi `dst` |
| R2 | `cron2conf.sh` odrzucal CALY crontab przy pierwszej linii z klamra, bo nie zaczyna sie ona od sciezki do `snapsend.sh`. Wada MOJA, wprowadzona razem z klamra; ta sama klasa co `-L` tego samego dnia |

### Stan po labie

Lab **stoi** i jest odtwarzalny: linie w `/root/replines.txt`, config w
`/root/replab.conf`. Crontab pve9 celowo **nietkniety** -- instalacja bloku z
niekanonicznej sciezki configu to zmiana, ktorej wlasciciel nie zlecil, a jeden
pisarz crontaba jest regula tego pakietu.

## LAB: replika na nosnik wymienny -- ZALICZONY (pve0, 2026-08-29)

Obowiazek reczny `mediagate-live` wykonany. Pula plikowa `rotlab` na `/root/rotlab.img`
w roli dysku wyjmowanego, zrodlo `rpool/mediasrc`. Host wrocil na `main`, po labie
nie zostal zaden dataset, pula ani obraz.

### Co zostalo dowiedzione

| | teza | pomiar |
|---|---|---|
| 1 | wyeksportowana pula czyta sie jako NIEOBECNA, nie jako awaria | `status` -> `is away (last seen: ...)`, `rc=1` |
| 2 | `attach` importuje i zapisuje wlasnosc | `imported-by-us` + `last-seen` w katalogu stanu |
| 3 | `detach` eksportuje to, co ten przebieg wzial | `exported ... the disk can be unplugged`, znacznik skasowany |
| 4 | **dysk wracajacy po dlugiej nieobecnosci bierze INKREMENT z kotwicy** | patrz nizej |
| 5 | brak dysku nie alarmuje | cala linia crona `rc=0`, `SKIPPED`, `Nothing was run and nothing is wrong` |
| 6 | awaria transferu przy WLOZONYM dysku alarmuje | silnik `rc=1` -> linia `rc=1`, pula mimo to wyeksportowana |
| 7 | swiezo przygotowany dysk daje sie zasiac | liscia `rotlab/replica/rpool/mediasrc` nie bylo; powstal, `rc=0` |

### Punkt 4 -- dowod, ze to inkrement, a nie przesiew od zera

Retencja zjadla na zrodle snapshot, ktory trzyma kopia. Zostala sama kotwica:

```
zrodlo po czystce:   rpool/mediasrc@automated_hourly2026-08-29_10-00-00
kotwica:             rpool/mediasrc#tgt-2e1a6b9f   guid 6543254757722584541
kopia trzyma:        rotlab/replica@automated_hourly2026-08-29_09-08-25   guid 6543254757722584541
```

GUID zgodny co do cyfry — kotwica i snapshot kopii to ten sam punkt. Po ponownym
imporcie i synchronizacji:

```
No common snapshot, but a bookmark still anchors an incremental: rpool/mediasrc#tgt-2e1a6b9f
```

**Kryterium zaliczenia nie jest jednak ten log, tylko dysk.** Przesiew od zera
musialby przyjsc z `-F` i zmiesc snapshoty celu. Stary snapshot PRZEZYL, doszedl
nowy, tresc pliku ma obie linie (`dane v1` + `dane v2`), a kotwica przesunela sie
na nowy punkt (`guid 13701617897984100`) zachowujac nazwe.

### Wady znalezione przez lab, wszystkie naprawione z kontrola ujemna

| | wada | dlaczego suita jej nie widziala |
|---|---|---|
| M1 | `zpool import` skanuje domyslnie `/dev`, wiec dysk OBECNY, ale poza ta sciezka, czytal sie jako nieobecny i zadanie pomijalo sie w nieskonczonosc bez slowa. Dodane `--dir` | stub `zpool` nie ma pojecia o sciezkach urzadzen |
| M2 | `detach` pytal KTO jest wlascicielem puli, zanim spytal CZY pula w ogole jest. Przy dysku w sejfie — czyli w przypadku najczestszym ze wszystkich — odpowiadal `leaving 'rotlab' imported`. To zdanie nazywa jedyny stan, w ktorym wyjecie dysku niszczy replike, wiec uczylo admina, ze prawdziwe ostrzezenie nic nie znaczy | suita przechodzila przy OBU kolejnosciach; niczego nie rozstrzygala |
| M3 | klamra byla wstawiana jako CIAG polecen w miejsce, ktore `job_cron_line` buduje pod JEDNO (`CMD 2>"$e"; rc=$?`), wiec `2>"$e"` i `rc=$?` wiazaly sie tylko z `detach`: stderr silnika szedl na stderr crona (ten sam zalew maili, ktoremu pakiet ma zapobiegac), a nieudany transfer zapisywal `rc=0` i nikt nie dostawal maila. Sens pola `media` polega na kupieniu JEDNEJ ciszy — kupowalo wszystkie. Teraz podpowloka i status WYBRANY, nie odziedziczony | suita badala bramke, nigdy linii |
| M4 | bramce podawano sciezke DOCELOWA, ktora tworzy silnik. Na swiezo przygotowanym dysku jej nie ma, wiec pierwsza synchronizacja byla odrzucana jako „zly nosnik" — wlasciwy dysk, odrzucony, i po M3 jeszcze alarmujacy. Nowego nosnika nie dalo sie zasiac. Tozsamoscia nosnika jest BAZA, ktora admin zaklada raz | jw. |

M3 i M4 to jedna rodzina: **testowalem czesc, ktora napisalem, a nie to, co z niej
wychodzi.** Sekcja G suity uruchamia teraz cala linie z prawdziwego `gen-cron.sh`.

### Zgloszone, nie naprawione

`snapsend.sh` loguje `Creating target dataset: <cel>` zanim sprawdzi, czy cel
istnieje — przy kazdej kolejnej synchronizacji mowi, ze tworzy dataset, ktorego
nie tworzy (kopia nie zostala odtworzona, stary snapshot przezyl). To wada opisu,
nie dzialania, i siedzi w ZAMROZONYM silniku: bez wyraznego polecenia wlasciciela
i wpisu w `ENGINE-FREEZE.md` nie ruszam.

## KAMPANIA: lab pasywny pve2>pve9 -- ZALICZONA (2026-08-23/24)

Wachlarz trzech relacji pasywnych z jednego zrodla, kazda innego ksztaltu, na
koncie delegowanym `bckp`, pod prawdziwym cronem, ze zewnetrznym generatorem
"cudzych" snapshotow co 5 minut (rotacja `serwis_`/`kopia_`/BEZ prefiksu +
rodzina wykluczona `smiec_`).

- **labP1** `hdd/labE1/at` z dziecmi, rekursja ATOMOWA (`-r`), join
  automatyczny (`--grant-remotely`), `-E smiec_`;
- **labP2** `hdd/labE2/at`, rekursja PLASKA (`-R`), join RECZNY (stop z
  instrukcja -> `--commit-scope` na zrodle -> wznowienie), `-E smiec_`,
  wykluczone dziecko `-X skip`;
- **labP3** `hdd/labE3/at`, pojedynczy dataset, join automatyczny,
  `-E smiec_`; jego zrodlo dostawalo WYLACZNIE wykluczone `smiec_` -- pulapka
  na monitor.

### Wynik czystego przelotu (start 23:56, odczyt 08:40)

**54 biegi cronowe, 54x rc=0** (27 backupow + 27 prune, 9 godzin pelnej
autonomii, werdykty czytane z pola `rc=` w logu -- status samej linii crona
jest zawsze 0 i nie jest dowodem). Rejestracje pierwszym podejsciem: P1 i P3
jedna komenda EXIT=0, P2 zaprojektowany stop -> commit operatora ->
wznowienie EXIT=0. Adopcje niezaleznie od nazwy: `20260823-222001` (BEZ
prefiksu), `serwis_*`, `kopia_*`. Wykluczone dziecko `skip` nieobecne na
targecie. Monitor labP3 przeszedl pelna sciezke `OK -> WARNING -> CRITICAL`
(34 wpisy CRIT w logu) MIMO swiezych `smiec_` co 5 minut -- nie dal sie
przekupic rodzina zadeklarowana jako wykluczona. To byl glowny pomiar
kampanii.

### Wady wykryte i naprawione po drodze (PR #142, #143, #144)

Dwa wczesniejsze przebiegi zostaly UNIEWAZNIONE przez wlasciciela ("ma byc
caly bez zaciecia") i posluzyly jako kampania lapania dziur:

1. **seed pasywny ignorowal wykluczenia** -- gola galaz `-e` adoptowala
   najnowszy snapshot czegokolwiek, w tym rodziny wykluczonej, gdy byla
   najswiezsza; seed renderuje teraz flagi przez `client_passive_flags`
   (#142);
2. **ciche przejecie konta** -- druga relacja z innym `--local-user` byla
   przestawiana na konto z manifestu parowania; add-client odmawia po imieniu
   (#142);
3. **kradziez hostkeya rodzenstwu** -- `alias_known_hosts` jest per HOST,
   alias per RELACJA; writer nadpisywal plik jednym wpisem (#143);
4. **brak delegacji lokalnego receive w trybie backup** -- `zfs allow` robil
   tylko branch sync; maskowane, bo seed idzie jako root (#143);
5. **wspolny multiplekser ssh** -- socket ControlMaster kluczowany tylko
   hostem i portem byl DZIELONY przez rownoczesne biegi, a `-O exit` na
   koncu biegu zabijal wspolnego mastera i scinal rodzenstwu transfer w pol
   strumienia. Awaria maksymalnie cicha: ssh 255 bez slowa, mbuffer czysty
   EOF, `recv` "failed to read from stream", sshd normalna sesja, ofiara
   losowa. Biegi sekwencyjne NIGDY nie padaly -- dlatego kazda reczna
   weryfikacja przechodzila, a prawdziwy tick crona nie. Socket per BIEG
   (`$$`); dowod: 6 rund x 3 rownoczesne relacje = 18/18 rc=0 (#144).

### Obserwacje, nie wady

- **Tryb atomowy niesie wykluczone snapshoty.** Na targecie labP1 wyladowalo
  18 snapshotow `smiec_`: `zfs send -R -I` z definicji przesyla WSZYSTKO z
  zakresu. Wykluczenia rzadza wyborem bazy, monitoringiem i prune -- nie
  zawartoscia strumienia atomowego. Targety plaski i pojedynczy: zero
  `smiec_`.
- **Kanal alertowy pve9 jest gluchy.** Monitor poprawnie krzyczal CRIT i
  `notify-fail.sh` strzelil, ale alert nie dotarl nigdzie: brak
  `/var/mail/root`, 4 wiadomosci frozen w kolejce exima, bounce'y do
  `bckp@pve9`. Wada srodowiska hosta laboratoryjnego, nie pakietu -- ale na
  produkcji nikt by o CRIT nie wiedzial.
- **Uprzaz pomiarowa klamala dwa razy**, produkt ani razu: rekonstruowana
  linia monitora bez `-R` dala falszywe OK, a `bash -c ""` na pustym
  wyciagnieciu linii dalo falszywe rc=0. Regula: uruchamiaj linie VERBATIM z
  crontaba.

### Rozbiorka

Relacje usuniete przez `remove-client` (kaskada rozpoznala kolejnosc: dopiero
ostatnia zwolnila parowanie), targety `labP*-tgt` zniszczone, rezydualny
config konta usuniety, linia generatora zdjeta z crontaba pve2 z DIFFEM
(11 -> 10 linii, usunieta wylacznie `# LAB-PASSIVE-GEN`), skrypt generatora
usuniety, `deploy.sh --leave=pve9` na zrodle, zrodla `hdd/labE1..3`
zniszczone. Produkcja pve2 zweryfikowana nietknieta (20 linii crontaba
`zfsbackup`). Na pve9 zostaja rezydua STARSZYCH labow (`hdd/lab9*`,
`hdd/pve2backup/...lab9src`, `hdd/pve2prodbackup/...lab9src`) -- nie z tej
kampanii, nie ruszane.

## Lab pasywny, pierwszy planowy tick — hydraulika kont (2026-08-23, galaz fix/multi-relationship-account-plumbing)

Pierwszy PLANOWY bieg crona (20:01) obnazyl dwie kolejne wady rodziny
wielorelacyjnej, obie maskowane przez to samo: idiom linii crona konczy sie
komenda, ktora zawsze wychodzi 0 — prawda jest wylacznie w polu rc= w
cron.log.

1. **Ostatnia rejestracja kradla hostkey rodzenstwu**: plik alias_known_hosts
   jest per HOST, alias per RELACJA; ensure_alias_known_hosts nadpisywal plik
   jednym wpisem — po trzech rejestracjach zostal tylko labP2 i kazdy
   planowy bieg rodzenstwa padal ssh 255. Writer podmienia teraz tylko
   wlasna linie aliasu.
2. **Tryb backup nigdy nie delegowal lokalnego receive**: zfs allow robil
   tylko branch SYNC; konto delegowane padalo na 'cannot receive incremental
   stream: permission denied' — niewidoczne, bo SEED idzie jako root, wiec
   targety wygladaly na zasilone. Backup dostaje ten sam
   ZFS_PERMS_LOCAL_RECEIVE na swojej bazie ladowania (target/<label>).

Dowod: trojka relacji od zera na tej galezi — plik aliasow z trzema wpisami,
delegacja 'user bckp' na kazdej bazie, wszystkie trzy linie verbatim jako
konto z PRAWDZIWYM rc=0 czytanym z cron.log. Lab nocny (starzenie monitora
na zrodle karmionym tylko wykluczonymi) biegnie dalej na tych poprawkach.
Notatka na przyszly etap: zachowawcza re-aktywacja to no-op — poprawki
docieraja do istniejacych relacji przez re-rejestracje.

## Lab pasywny — pierwsze znaleziska (2026-08-23, galaz fix/passive-seed-exclusions)

Pelny lab pasywny (3 zrodla na pve2, kszalty: -r/auto/bckp, -R/reczny join,
plaski/auto; generator cudzych snapshotow co 5 min z rotacja prefiksow i
rodzina wykluczona smiec_) ruszyl i w pierwszej godzinie zlapal dwie wady:

1. **Seed pasywny ignorowal wykluczenia**: gola galaz -e adoptowala
   najnowszy snapshot CZEGOKOLWIEK — w tym rodzine zadeklarowana jako
   wykluczona, gdy byla najswiezsza (zmierzone: seed wyslal smiec_* na
   target, podczas gdy linia crona obok niosla -E smiec_). Kampania
   zamykajaca tego nie widziala, bo jej smiec_ byl akurat starszy. Seed
   renderuje teraz flagi przez client_passive_flags — to samo zrodlo pol i
   ten sam renderer co linia instalowana.
2. **Ciche przejecie konta**: druga relacja z innym --local-user byla po
   cichu przestawiana na konto z manifestu parowania (zmierzone:
   --local-user=root wyladowal w crontabie bckp, configu bckp, na kluczach
   bckp, bez slowa). add-client odmawia teraz po imieniu; wybor konta jest
   tez zapisywany na rekordzie relacji (LOCAL_USER, slot r_user). Pelne
   wsparcie kont mieszanych per host (osobne tozsamosci parowania) = osobny
   przyszly etap.

Lab nocny zostaje uruchomiony (labP1/labP2/labP3 aktywne, generator tyka):
rano odczyt monitorow — labE3 dostaje TYLKO wykluczone smiec_, wiec jego
monitor ma zestarzec sie do WARN/CRIT mimo swiezych wykluczonych snapshotow.

## Parowanie wielorelacyjne (2026-08-23, galaz feat/multi-relationship-pairing)

Sciana "jedna relacja na hosta zrodlowego" zburzona. Target jest faktem
RELACJI: rekord klienta zapisuje CLIENT_TARGET przy create, a
load_client_and_connection nadpisuje nim per-hostowy PEER_SAVED_TARGET z
manifestu parowania (pusty/nieobecny = zachowanie manifestu, zero migracji).
Klucze, zaufanie hosta i konto delegowane zostaja per-host z projektu
(1 config = 1 konto, LAB6). Dowod na zywo pve9<-pve2: dwie rownolegle
relacje (labS, labD) do wlasnych targetow — obie EXIT=0 od zera, osobne
przestrzenie nazw, scope zrodla z dwiema stanzami (rozszerzenie z #140),
filtr REQUESTED_DATASETS pomija korzen rodzenstwa, oba crony rc=0 jako bckp.
Kontrola negatywna: trzecia relacja celowo mierzaca w target labS odmowa
przez straznik pokrycia (EXIT=1, fail-closed nietkniety).

Nieobjete tym etapem: rozne --local-user dla relacji do TEGO SAMEGO zrodla
(manifest trzyma jedno konto per host) — zmierzy to pelny lab pasywny.

## Rodzina seeda z profilu + granice wielorelacyjne (2026-08-23, galaz fix/seed-family-prefix)

Zakladnik `automated_` usuniety: rodzina seeda pochodzi z AKTYWNEGO PROFILU
(`profile_family_root`: gfs_pattern, inaczej prefiks nadawczy bez slowa tieru,
inaczej sam prefiks; pusty -> automated_). Seed = korzen+`daily_` — dla
profilu domyslnego bajt w bajt to samo `automated_daily_`. Szesc miejsc
przestawionych: oba seedy, oba probingi pasywnosci wokol nich, detekcja
konsumenta w sync, galaz adopcji. Kontrola (profil `serwis`, przed poprawka):
seed stemplowal `automated_daily_` po obu stronach relacji, ktorej cala
retencja prunuje `serwis_*` — snapshot na wieki poza retencja + zatruta sonda
`automated_*` na zrodle. Lancuch inkrementalny NIE byl zepsuty (baza po GUID,
zmierzone). Po poprawce: serwis od zera EXIT=0, seed `serwis_daily_`, zero
`automated_`; regresja default od zera EXIT=0, seed `automated_daily_`.

Przy okazji, z tej samej baterii pomiarowej:

- **Konta delegowane pisza telemetrie postepu**: katalog progress byl 2755
  (konto w zfsalert bez `w` — zero rekordow z jobow konta), provisioning
  ustawia 2775 root:zfsalert; do tego `2>/dev/null` PRZED przekierowaniem
  wyjscia w progress_done/progress_mark_verified (padajacy open lecial na
  oryginalny stderr — jedna linia 'Permission denied' na dataset w cron.log).
- **--grant-remotely ROZSZERZA zacommitowany scope** zamiast slepego "nothing
  to grant": brakujace stanzy zadania dopisane + ponowny --commit-scope,
  tylko gdy bajty pliku == granted hash (szkic operatora dalej odmawia);
  audyt `GRANTED_REMOTELY_BY ... (extension)`.
- **Relacja rozwiazuje SWOJ grant, nie caly scope kolektora**: scope jest
  per-kolektor i po drugiej rejestracji to UNIA — labD widzial drzewa labS
  (tylko straznik --yes stal przed replikacja cudzych datasetow). Rekord
  klienta zapisuje REQUESTED_DATASETS przy create; resolucja pomija korzenie
  rozlaczne z zadaniem (korzen OBEJMUJACY zadanie zostaje — adopcja szerszego
  grantu to swiadoma zgoda operatora, jak dotad).

GRANICA NA OSOBNY ETAP (fail-closed, zmierzona): parowanie jest per-HOST —
jeden PEER_TARGET i jedna etykieta na hosta zrodlowego. Druga relacja do tego
samego zrodla dziedziczy target pierwszej i straznik pokrycia ja odmawia.
Wielorelacyjnosc do jednego zrodla wymaga rozdzielenia tozsamosci parowania.

## Kampania zamykajaca trybu pasywnego (2026-08-23, galaz fix/grant-preflight-order)

Jednokomendowa rejestracja pasywna od zera (`--source=... --passive
--exclude-family=smiec_ --grant-remotely --install --yes`, pve9<-pve2 po
tunelu WireGuard) przechodzi za pierwszym podejsciem: EXIT=0, zrodlo
nietkniete (md5 listy snapshotow przed/po identyczne), zaadoptowany najnowszy
niewykluczony obcy snapshot (`bez-prefiksu-103`; `smiec_102` pominiety).
Zainstalowana linia backupu niesie `-e -m "" -E smiec_`, linia monitora
wzorzec `-` i `-x smiec_`; obie uruchomione verbatim jako `bckp` daja rc=0.

Cztery wady znalezione i usuniete po drodze (kazda najpierw zmierzona):

1. preflight grant-remotely odrzucal czysty host — test manifestu bramkowany
   na will_join_now;
2. `${2:-automated_}` zjadal pusty prefiks („dowolna rodzina") — `${2-...}`;
3. rux nie przekazywal `--exclude-family` i `--passive` do add-client;
4. watcher postepu dziedziczyl flock silnika (fd 200) i przezywal bieg —
   kazda PIERWSZA rejestracja padala na verify („Another instance"), a kazda
   reczna proba przechodzila; `exec 200>&-` w watcherze. Wykryte dopiero po
   tym, jak bezwerdyktowa galaz sondy nauczyla sie pokazywac stderr silnika.

Odswiezanie klonu konta przepisane: root twardo synchronizuje kopie konta do
HEAD wlasnego checkoutu (`fetch $SCRIPT_DIR HEAD` + `reset --hard` +
`chown -R`, z `-c safe.directory`), zamiast ufac originowi i galezi zastanego
klonu — zmierzony przypadek: klon na porzuconej galezi wip z nieosiagalnym
originem cicho przezywal refresh i odrzucal swieze linie (`monitor_exclude
... not a field`). Laboratorium (labP/labE) rozebrane na obu hostach;
produkcja pve2 zweryfikowana nietknieta.

## 1. Co jest wdrożone, gdzie i w jakiej wersji

Trzy osiągalne hosty potwierdzone na `a567328` (2026-08-04 23:44, wymuszony
`--self-update` na każdym; godzinowy pull o :15 działa niezależnie). Czwarty,
pve1 klastra 192.168.11.x, nie był w tej sesji aktualizowany — patrz uwaga o
DEGRADED rpool niżej.

**`deploy.sh --check-only` czysty na wszystkich trzech osiągalnych**
(`audit clean on pve0` / `pve1` / `pve2`), zweryfikowane 2026-08-04 23:44 po
naprawie dwóch usterek opisanych w nagłówku: brakującego katalogu blokad na
pve0 i brakującej bazy aliasów na metropolis pve2.

Repo na hostach mieszka w `/root/scripts/zfs-snapshot-all` (nie
`/root/zfs-snapshot-all`), a konto delegowane ma własny checkout w
`/home/zfsbackup/zfs-snapshot-all`.

| Host | Adres | Konto delegowane | `sudo` | grant quiesce | kto uruchamia blok |
|---|---|---|---|---|---|
| pve0 | 192.168.11.10 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| pve1 | 192.168.11.11 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| metropolis pve1 | 192.168.28.9 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |
| metropolis pve2 | 192.168.28.8 | `zfsbackup` | jest | **NADANY** | **`zfsbackup`** |

**Wszystkie cztery hosty mają blok na koncie delegowanym.** Metropolis pve1 od
2026-08-01 18:10, pve2 21:44, pve1 (11.11) 23:02, pve0 23:05. W crontabie roota
zostały wszędzie trzy linie ogólnohostowe: `check-pool-capacity.sh`,
`update-control.sh --self-update` i `alert-digest.sh`. Configi mieszkają w
`/etc/zfs-snapshot-all/` — **przeniesione**, nie skopiowane.

Stan potwierdzony na żywo 2026-08-02 na wszystkich czterech: `sudo -n
zfs-quiesce-helper status` jako konto → `OK account=zfsbackup`, whitelista
niepusta, helper na miejscu, zero zadań backupowych w crontabie roota.
Liczba linii zadań na koncie: pve0 28, pve1 (11.11) 8, metropolis pve1 12,
metropolis pve2 14.

> Ta tabela do 2026-08-02 twierdziła, że klaster 192.168.11.x „nadal w całości
> na roocie i nie ma tam nawet konta delegowanego". Było to nieprawdą od
> 2026-08-01 wieczorem — migracja objęła wszystkie cztery hosty tej samej nocy,
> a dokument został odświeżony tylko w sekcjach o recenzjach. Dokładnie ten typ
> rozjazdu, o którym mówi nagłówek.

pve2 doszedł tam okrężną drogą: jego config **nie istniał** (patrz niżej),
więc najpierw trzeba go było odtworzyć z żywego crontaba `cron2conf.sh`.
Round-trip wyszedł bajt w bajt: 12 wyrenderowanych linii identycznych z
zainstalowanymi, w tej samej kolejności.

Wersje programów w drzewie:

| Program | Wersja |
|---|---:|
| `snapsend.sh` | `v2.68` |
| `snapget.sh` | `v2.65` |
| `delsnaps.sh` | `v1.28` |
| `gen-cron.sh` | `v4.25` |
| `check-snap-age.sh` | `v2.0` |
| `cron2conf.sh` | `v1.0` |

`deploy.sh`, `zfs-backup.sh`, `zfs-quiesce-helper.sh`, `update-control.sh` i
`check-pool-capacity.sh` nie mają własnej stałej `VERSION` — identyfikuje je
commit.

`cron2conf.sh` (nowy, 2026-08-01) jest odwrotnością `gen-cron.sh`: czyta już
zainstalowany blok `# BEGIN/END zfs-backup-managed` z crontaba i odtwarza
config, z którego `gen-cron.sh` wygeneruje ten sam blok z powrotem — na
wypadek zgubienia/niescommitowania pliku źródłowego, jak w przypadku pve2
niżej. Nie ma jeszcze wpisu w `deploy.sh` (nie jest kopiowany na hosty) —
uruchamiany dziś ręcznie z checkoutu deweloperskiego, tak jak został
zweryfikowany na pve1 i pve2.

### Stan grantu quiesce na hostach: DWA NADANIA, produkcyjne

**metropolis pve1 od 17:54, metropolis pve2 od 21:43** — pierwsze trwałe granty
quiesce w całej flocie, i pierwsze nadane *lokalnym* kontom tych hostów, a nie
sparowanym peerom. Na pve2 `deploy.sh` doinstalował przy okazji brakujący pakiet
`sudo`, jak zapowiada. Poniżej pve1; pve2 ma ten sam kształt, z whitelistą
`rpool/data rpool/ROOT/pve-1 hdd/vm-disks hdd/backups` i jedynym lokalnym
gościem 103 (reszta dysków pod tymi ścieżkami to repliki, których konfiguracje
żyją na pve1 — helper zgłasza je jako `kind=absent`, więc są niezamrażalne):

| Element | Wartość |
|---|---|
| konto | `zfsbackup` |
| reguła | `/etc/sudoers.d/zfs-quiesce-zfsbackup` (0440 root:root) |
| whitelista | `/etc/zfs-quiesce-allow/zfsbackup` — sześć datasetów **dokładnie tych, które nazywa config** |
| polecenie | `deploy.sh --backup-user=zfsbackup --datasets="…" --allow-quiesce` |

Zweryfikowane **jako konto**, nie jako root: `sudo -n zfs-quiesce-helper status`
→ `OK account=zfsbackup`; guesty 100, 101, 106 i 107 (te, których dyski config
backupuje) przechodzą z kodem 0; guest **102 odmówiony kodem 2** — jego dysk leży
pod `hdd/vm-disks`, ale nie jest w configu. To jest cała racja bytu wyprowadzania
whitelisty z listy datasetów zamiast z puli: gdyby `--datasets` nazwało rodzica,
konto mogłoby zamrozić maszynę, której nie ma powodu dotykać.

Ta droga nadania **nie istniała** do 2026-08-01 — `--allow-quiesce` działało
wyłącznie razem z `--join`, czyli tylko dla peera. Zdolność, o którą preflight
migracji się potykał, nie miała żadnego polecenia, które by ją nadawało
(`3831509`, doprecyzowane przez REV-022 w `32d6ed1`).

Na pve0 i pve1 (192.168.11.x) grant **jest** od migracji 2026-08-01 wieczorem —
reguła `sudoers.d`, whitelista i helper na obu. Whitelisty różnią się zakresem,
bo wyprowadza je config danego hosta: pve0 pięć datasetów
(`rpool/data`, `hdd/data/vm-101-disk-0`, `hdd/lxc/subvol-102-disk-0`,
`hdd/lxc/subvol-102-disk-1`, `hdd/backups/pve1`), pve1 (11.11) jeden
(`rpool/data`). Zdanie o „zero reguł" w tym miejscu opisywało stan sprzed
migracji i było nieaktualne od tamtego wieczora.

Pozostałości po testach z 2026-07-31 **są** i trzeba je czytać jako stan, nie
jako zero:

| Host | Co zostało | Skąd |
|---|---|---|
| pve0, pve1 (192.168.11.x) | pakiet `sudo` | przebiegi `--allow-quiesce` 14:35 i 15:45 |
| metropolis pve1 | pakiet `sudo` **oraz `/usr/local/sbin/zfs-quiesce-helper`** | pełny cykl end-to-end zakończony `--revoke-quiesce` |

To jest dokładnie stan opisany w REV-20260731-009 §5: pakiet zostaje, granta nie
ma, i od `ad5e745` kod mówi o tym wprost przy każdej takiej awarii. `--revoke`
zdejmuje **regułę** — to ona jest przełącznikiem — a binarkę helpera zostawia;
bez reguły jest ona martwym plikiem. Potwierdzone na żywo:
`runuser --user zfsbackup -- sudo -n /usr/local/sbin/zfs-quiesce-helper status 106`
→ `sudo: a password is required`.

Poprzednia wersja tej sekcji twierdziła, że helpera nie ma na żadnym hoście i że
metropolis pve1 nie ma `sudo`. Oba zdania były nieprawdziwe od 2026-07-31.

**Instalacja end-to-end: WYKONANA 2026-07-31 na metropolis** (za zgodą
właściciela). Pełny cykl `--pair` → przeniesienie paczki → `--join
--allow-quiesce` → weryfikacja granicy → aktualizacja z szerszą listą →
`--revoke-quiesce` → `--unpair` + teardown. Szczegóły i hashe w odpowiedzi na
REV-20260731-012.

Co to dało — rzeczy, których piaskownica nie umiała pokazać: prawdziwy `visudo`
przyjął regułę; konto delegowane dosięgło helpera przez sudo; guest na `rpool/data`
przeszedł, a guesty na puli `hdd` zostały odmówione; **`env_reset` udowodniony z
kontrolą nośności** (ta sama zmienna działa, gdy dociera do helpera, i nie działa
przez sudo); forma argumentowa nie pasuje do reguły i w ogóle nie startuje;
ścieżka aktualizacji z REV-012 zostawiła regułę bajt w bajt tą samą i zero
`.zqg-*`; po odwołaniu konto traci dostęp całkowicie; crontaby obu maszyn
identyczne przed i po.

Świadomie zostawione, wszystko zapowiedziane przez kod: pakiet `sudo`, binarka
helpera (współdzielona) i pusty dataset testowy w `hdd/backuptest_targets/`.

**Freeze/thaw na produkcyjnym guescie: WYKONANY 2026-07-31 21:27** na VM 106
(`vbim2`, Windows, metropolis pve1), pełną ścieżką konto delegowane → sudo →
helper:

```
przed:     thawed   21:27:19
froze VM 106 via qemu-guest-agent   rc=0
w trakcie: frozen   21:27:23      <- potwierdzone przez qm, nie deklaracją helpera
thawed VM 106                       rc=0
po:        thawed   21:27:25
```

Zamrożenie zajęło ~4 s (przygotowanie VSS), samo okno zamrożenia ~2 s. Po
wszystkim guest `running`, agent odpowiada. Test szedł w **jednym** wywołaniu z
trapem odmrażającym rootem, a termin replikacji `106-0` (co 3 h) był wcześniej
odczekany — pvesr mrozi tego samego guesta i kolizja byłaby najgorszym możliwym
momentem.

Ten sam przebieg znalazł realny błąd w `sqlfreeze`, patrz sekcja 4.

**Czego nadal nie ma:** ścieżki błędów `install`/`mv`/`visudo` oraz crash są
wyłącznie stubowane — na produkcji przeszedł happy path.

**Snapshot w oknie zamrożenia: WYKONANY 2026-08-01 18:21**, przez konto
delegowane, na wszystkich pięciu datasetach naraz (`froze VM 106 via
qemu-guest-agent` → dwa atomowe `zfs snapshot`, po jednym na pulę → `thawed VM
106`, guest `thawed` przed i po). Czyli to, czego brakowało powyżej, jest
zrobione — ale przebieg odsłonił **inny** problem, opisany niżej.

**Okno zamrożenia: NAPRAWIONE** (REV-20260801-024, `be1cfe7` + `d8bb52a`).

Defekt: VM 106 zamrożony 18:21:21, snapshot 18:21:39 — **~18 s**, z czego 16 s to
`pct exec 101 -- sync` lecący **po** zamrożeniu. VM 106 to `ostype: win10`, a VSS
zwalnia freeze po ~10 s samo z siebie. Czyli snapshot powstawał poza oknem, które
deklarował, i wszystkie kontrole to akceptowały — bo freeze *się udał*, tylko już
nie obowiązywał. Niezależne od migracji: root miał tę samą kolejność.

Poprawka ma trzy części i wszystkie trzy są potrzebne:

| | co | gdzie |
|---|---|---|
| kolejność | `quiesce_prepare` (wolne: flush kontenerów, decyzje, odmowy — **zero freeze'ów**) i osobne `quiesce_freeze_pending` tuż przed snapshotem | `lib-zfs-snap.sh` |
| ponowny odczyt | `quiesce_still_frozen` pyta każdą VM jeszcze raz **bezpośrednio przed** `zfs snapshot`; nie-zamrożona albo nieodczytywalna przerywa | `lib-zfs-snap.sh` |
| termin | `QUIESCE_MAX_WINDOW` (5 s, przy limicie VSS ~10 s), mierzony i **logowany**, przekroczenie = błąd, nie ostrzeżenie | `lib-zfs-snap.sh` |

Zmierzone na żywo po poprawce: **okno 1 s** (było 18), przy kontenerach
flushowanych 51 s — czyli dłużej niż wcześniej, i to jest właśnie sedno: ten czas
nie dotyka już okna.

> **Pierwsza wersja poprawki miała własny błąd i znalazł go dopiero pomiar.**
> `be1cfe7` startował zegar przed **wywołaniem** freeze'u, a `fsfreeze-freeze` na
> Windows wraca po ~4 s (VSS się przygotowuje — guest nie jest wtedy zamrożony).
> Produkcyjny przebieg wypisał `freeze window 5s (budget 5s)` — przeszedł
> zerowym marginesem. `d8bb52a` startuje zegar przy **pierwszym udanym**
> zamrożeniu. Znowu: wykryte przez przeczytanie liczby, nie przez test.

**Nieobjęte:** ścieżka zdalna (`snapget -q`) ma własną kopię tej logiki w
`ZFS_REMOTE_QUIESCE_SCRIPT`. Ten konkretny kształt (16 s flushu w środku okna)
nie może tam wystąpić, bo freeze/snapshot/thaw idą w jednym wywołaniu — ale nie
ma tam ani ponownego odczytu na granicy, ani terminu. Ta sama rodzina, świadomie
poza tym commitem.

## 2. Zaakceptowany rdzeń

Bez zmian wobec uzgodnienia z 2026-07-30. Przyjęte jako działające: snapshoty
ZFS; replikacja push i pull, lokalnie i przez SSH; tryb zwykły, rekurencyjny i
rozwijany per dataset; dopasowanie baz incremental po nazwie, GUID i bookmarku;
wznawianie transferów; `zfs hold` w locie; kompresja, limit pasma i autotuning;
quiesce VM/CT; retencja wiekowa, liczbowa i GFS; usuwanie osieroconych
bookmarków; monitoring wieku snapshotów i pul; generowanie zadań z INI;
praca jako root i przez konta delegowane; bootstrap i audyt hosta; `--pair`,
`--join`, rotacja, odwołanie klucza i `--unpair`; zewnętrzny kontroler
aktualizacji i rollbacku.

## 3. Transakcja nadania grantu quiesce — stan bieżący

Ta sekcja istnieje, żeby nie trzeba było odtwarzać projektu z trzech
chronologicznych odpowiedzi. **To jest opis kodu, który jest w drzewie teraz.**

`install_quiesce_grant()` operuje na trzech plikach:

```
/usr/local/sbin/zfs-quiesce-helper      kod, WSPÓŁDZIELONY przez wszystkie peery
/etc/zfs-quiesce-allow/<konto>          które guesty konto może zamrozić
/etc/sudoers.d/zfs-quiesce-<konto>      sam grant; bez niego nic nie jest nadane
```

Kolejność faz: zależności → generowanie i walidacja w `mktemp` → utworzenie
katalogu whitelisty → **sweep** pozostałości po przerwanym przebiegu → staging →
kopie zapasowe → **commit** → sprzątanie.

**Nic nie jest zapisywane w miejscu.** Każdy plik ląduje jako `<cel>.zqg-new` we
własnym katalogu docelowym i jest przemianowany na cel. `rename(2)` jest atomowy,
więc każda chwila crashu zastaje cały stary albo cały nowy plik. Staging obok
celu, a nie w `/tmp`, jest tym, co czyni z tego rename zamiast kopii przez
granicę systemu plików.

**Kolejność commitu — najpierw wyłączenie aktywnego grantu:**

```
0. mv  <reguła>            <reguła>.zqg-bak     zawieszenie grantu (tylko update)
1. mv  <whitelista>.zqg-new <whitelista>
2. mv  <helper>.zqg-new     <helper>
3. mv  <reguła>.zqg-new     <reguła>            uzbrojenie nową regułą
```

Każda przerwa daje stan o **mniejszych** uprawnieniach niż na starcie. Krok 0 jest
pomijany przy pierwszej instalacji, więc świeży enroll nie ma przerwy w dostępie.

Wcześniejsza wersja commitowała whitelistę jako pierwszą, uzasadniając to tym, że
jest „ograniczeniem". To było błędne i wyłapał to REV-20260731-012: przy
**aktualizacji** finalna reguła już istnieje i jest aktywna przez cały commit, więc
szersza whitelista działa od momentu swojego rename — a crash utrwalał poszerzenie.

Zawieszenie jest samo w sobie rename, na ignorowaną nazwę `.zqg-bak`, więc jest
atomowe i **jest** krokiem zachowania kopii dla reguły. Dlatego reguła jako jedyna
nie dostaje twardego dowiązania: `rename()` na dwie nazwy tego samego i-węzła jest
wg POSIX no-opem, więc dowiązanie sprawiłoby, że reguła zostałaby żywa przez cały
update — cichy powrót tego samego defektu, przy zielonym pakiecie testów.

Koszt: okno w trakcie aktualizacji, w którym konto nie może zamrozić niczego.
Świadomy wybór — nieudany job jest widoczny i ponawiany, po cichu poszerzony grant
nie jest.

**Przerwana aktualizacja zostaje WYŁĄCZONA i taka pozostaje**, dopóki jakiś
przebieg się nie dokończy. Sweep rozróżnia trzy przypadki: `.zqg-new` → usuń
(martwy staging); `.zqg-bak` przy istniejącym celu → usuń (kopia zbędna);
`.zqg-bak` **bez celu** → **zostaw zaparkowane**, nie uzbrajaj.

Wcześniejsza wersja przywracała taką kopię z powrotem, w obawie o utratę jedynego
egzemplarza. Wyłapał to REV-20260731-013: w momencie parkowania reguły poprzedni
przebieg zdążył już wgrać nową, **szerszą** whitelistę — więc przywrócenie starej
reguły uzbrajało ją przeciwko tej whiteliście. To samo poszerzenie, które zamknął
REV-012, przeniesione z commitu do odzyskiwania. Nic nie ginie przez parkowanie:
plik leży pod nazwą, którą sudoers.d ignoruje, a `pre_rule` liczone jest po
sweepie, więc krok 0 się pomija i nowa reguła wchodzi jako ostatnia.

**Rollback rozróżnia tworzenie od nadpisania.** `pre_*` mówi „istniał, więc
przywróć", `did_*` mówi „próbowano zapisu, więc się tym zajmij" i jest ustawiane
**przed** commitem. Dla helpera i whitelisty kopia zapasowa to **twarde
dowiązanie** do oryginalnego i-węzła — niesie treść, właściciela, tryb i xattry
przez tożsamość, nie przez kopię, która mogłaby coś zgubić. Dla reguły kopią jest
sam rename zawieszający (powód wyżej). Przywracanie to w obu przypadkach rename,
więc rollback też jest atomowy. Komunikat rozróżnia „przywrócono poprzedni grant"
od „usunięto to, co ten przebieg utworzył", a nieudane przywrócenie krzyczy
zamiast udawać sukces.

**Recovery to „uruchom ponownie".** Pozostałości są zamiatane i raportowane, nigdy
odtwarzane — funkcja i tak przepisuje wszystkie trzy cele, więc odtwarzanie połowy
intencji byłoby zgadywaniem. Jedyny wyjątek to opisane wyżej przywrócenie kopii,
która została jedyną.

**Detal nośny dla całości:** `/etc/sudoers.d` jest czytany przez sudo, a staging
reguły w środku jest bezpieczny **wyłącznie** dlatego, że sudoers.d ignoruje każdą
nazwę zawierającą kropkę. Zweryfikowane na żywym `visudo 1.9.5p2` w izolowanym
drzewie, z kontrolą negatywną. Ta sama reguła w drugą stronę: konto z kropką w
nazwie dałoby finalną regułę niewidoczną dla sudo — `pc_is_account` tego zabrania.
Ponowna weryfikacja przy każdej aktualizacji sudo jest zapisana w `deps.conf`.

Pakiet `sudo` instaluje **wyłącznie** ta funkcja, czyli tylko przy
`--allow-quiesce`. Zwykły deploy nie dotyka pakietu.

## 3b. Profil wdrożeniowy (`zfs-backup.sh`) — stan bieżący

Wysokopoziomowy przepływ ukrywa wewnętrzne kroki parowania, zakresu i aktywacji:

```
add-client → deploy.sh --join (na źródle) → seed → activate
                                                → status / test / remove-client
```

Normalne `add-client NAME --host=... --target=...` domyślnie wybiera tryb
`backup`; operator kolektora nie podaje ani `--mode=backup`, ani datasetów
źródła. Prowadzony `deploy.sh --join=PAKIET` na źródle tworzy konto i klucz,
odkrywa realny układ ZFS, pokazuje aktywny zakres i daje wybór: zaakceptuj albo
edytuj. Dopiero akceptacja waliduje zakres i nadaje grant. Przerwanie kończy
się jedną komendą ponowienia całego `--join`; ponowienie po sukcesie rozpoznaje
zgodny scope+sha256 i niczego nie dubluje.

`--datasets="A B"`, jawne `--mode=backup|sync`, `--draft-scope` i
`--commit-scope` pozostają ścieżką ekspercką. Dla klienta trybowego
`load_client_and_connection` woła
`resolve_mode_datasets`, które dla klienta trybowego pobiera committed
scope peera przez ssh, weryfikuje sha256 (T3) i wylicza realną listę
liści przez zdalne `zfs list -r`, wypełniając `PEER_SAVED_DATASETS`
dokładnie tak, jak zrobiłby to ręcznie podany `--peer-datasets`. Wynikiem
`activate NAME [--host=NOWY]` jest GOTOWY config i cron: komenda bierze
odpowiedzialność za końcowy catch-up przed zmianą adresu, `set-endpoint` gdy
adres rzeczywiście się zmienia, `verify-endpoint`, podgląd configu/crona i
transakcyjne `activate-client`. Po każdym podkroku ponownie czyta rekord
relacji; dlatego retry wznawia, a powtórzenie już aktywnej relacji jest no-op.
Niskopoziomowe czasowniki pozostają narzędziami diagnostycznymi i naprawczymi.

**Jedna kadencja wysyłki, jedna drabina.** Na klienta generuje się: jedna linia
`snapget` per dataset (co godzinę o :01), jedna
`delsnaps -G -R <cel>/<label> "automated_" -H24 -D7 -W4 -M12` (o :21) i **jeden**
monitor na `automated_hourly`.

Wcześniejsza wersja miała cztery kadencje wysyłki obok drabiny — REV-016 wykazał,
że to łączy oba modele bez korzyści z żadnego: `-G` kubełkuje po **czasie** i nie
patrzy na prefiks, więc wysyłki dzienna/tygodniowa/miesięczna nie definiowały
żadnego tieru, tylko dokładały snapshoty i transfery, w dodatku startując o tej
samej minucie.

Progi monitora są **tylko** na najdrobniejszym tierze — monitor na
`automated_daily` pilnowałby wzorca, którego nic nie tworzy, i stałby na CRITICAL
w nieskończoność.

**Akceptacja przed instalacją.** `activate-client` pokazuje dwa diffy: proponowany
config oraz zmianę w cronie, gdzie lewa strona to **realnie zainstalowany blok**
odczytany z `crontab -l`, a nie ponowny render configu. Nieczytelny crontab
przerywa przed pytaniem — „nie dało się odczytać" to nie to samo co „jest pusty".

**Migracja starego profilu** to akcja narzędzia (`migrate-profile`), nie ręczna
edycja szablonów: usuwa stare szablony, przebudowuje aktywnych klientów tą samą
funkcją co aktywacja, waliduje, pokazuje diff i pyta raz.

**Faza 4 (2026-08-10, commit `9074fe5`): `add-client --profile=NAME`.** Wybór
profilu w momencie CREATE, walidowany (`profile_validate_dir`) zanim dojdzie
do parowania, zapisywany w rekordzie klienta. Pominięty → `default`, ścieżka
bez wyboru bez zmian. `activate-client` czyta ten wybór **wyłącznie** przy
pierwszej aktywacji (`apply_client_profile_choice()`) — reaktywacja nigdy go
nie konsultuje, ta sama jednokierunkowa granica co REV-089 dla profilu w
ogóle, więc stary rekord klienta sprzed tej zmiany (bez pola `PROFILE`) to
no-op, zero migracji. Podgląd „candidate CONFIG + cron przed instalacją" już
istniał (`show_activation_proposal`/`atomic_replace_and_install`) — nic
nowego tu nie trzeba było budować. Obecnie istnieje tylko jeden profil
(`profiles/default`), więc realna wartość na razie to sam mechanizm wyboru;
kolejne nazwane profile to osobna decyzja produktowa, nie ta zmiana.
`test/zfsbackup/run.sh` sekcja 53: 358/358 (cała suita). Nie wykonane:
`zfsbackup-live-pair` (potrzebuje dwóch żywych hostów + root — realny
`deploy.sh --pair`/`snapget.sh -n`/`gen-cron.sh --install`), zgłoszone jako
obowiązek ręczny.

**Limit pasma** `--bandwidth=N` (bajty/s, `mbuffer -r`) jest **per proces
transferu**, nie sumaryczny dla relacji. W praktyce dla pojedynczego zadania
znaczy to tyle samo: datasety w jednym wywołaniu `snapsend` idą sekwencyjnie
(snapsend.sh:2012 — bez `&`), a generator scala datasety o wspólnym
harmonogramie w jedną komendę. **Ale dwa nakładające się zadania tej samej
relacji** (np. przeciągnięty hourly i startujący daily) **sumują się do 2×N** —
dziś zamek w `snapsend` jest kluczowany na `(datasety, cel, prefiks)`, więc łapie
hourly-na-hourly, a nie hourly-na-daily. Naprawa jest w NOW (zamek kluczowany
etykietą relacji). Pułap **całego kolektora** to osobna sprawa, świadomie
odłożona — kilka relacji nadal może sumować się ponad N.

**Pełny cykl przetestowany na żywo 2026-08-01** (metropolis, pve1 jako kolektor
jako root, pve2 jako źródło): `setup-server` → `add-client` → paczka → `--join` →
`seed` (40 MB realnego transferu) → `verify-endpoint` → `activate-client` →
uruchomienie wszystkich trzech wygenerowanych linii → `remove-client` → teardown.

Wynik: 15 → 18 linii crona, **każda produkcyjna linia obecna co do znaku**, po
teardownie crontab **identyczny** ze zrzutem sprzed testu, zero pozostałości na
obu hostach. Drugi transfer był przyrostowy (cel nie urósł), drabina GFS zostawiła
najnowszy snapshot i usunęła starszy z tego samego kubełka, monitor `rc=0`.

Test znalazł **realny błąd**, którego żaden test lokalny nie mógł znaleźć: drugi
argument `snapget.sh` to baza lokalna, a wrapper podawał ścieżkę końcową — seed
lądował o poziom za głęboko, niewidoczny dla zadania crona (`base=null`, pełny
transfer w kółko), a `verify-endpoint` meldował sukces, bo szukał w tym samym złym
miejscu. Naprawione, zapięte testem parzystości z generatorem.

Nie zrobione: konto dedykowane na kolektorze **nie zostało przetestowane na żywo**
(kod jest, test przeszedł w kształcie rootowym); `migrate-profile` przetestowany
tylko w częściach składowych.

## 4. `sqlfreeze` — co dowodzi, a czego nie

`zfs-quiesce-helper sqlfreeze <id> [sekundy]` czyta zdarzenia SQL Server 3197
(„I/O is frozen") i 3198 („I/O was resumed").

Odpowiada na: *czy SQL brał udział w co najmniej jednym freeze/resume w tym
oknie*. **Nie** odpowiada na: *czy zrobił to ten konkretny backup* — zdarzenie nie
niesie tożsamości requestera. Werdykt niesie to zastrzeżenie w swoim własnym
wyjściu.

Liczenie jest **per instancja** (`MSSQLSERVER`, `MSSQL$<nazwa>`), nigdy per baza:
nazwa bazy jest w tłumaczonym tekście komunikatu, a parsowanie tłumaczeń to błąd,
który wcześniej wywrócił parser `writers`.

Nie jest wpięty w żaden automatyczny werdykt: ani w profil `standard`
`zfs-backup.sh`, ani w żadną linię crona, i żadna ścieżka kodu nie czyta jego kodu
wyjścia.

**Poprawka z 2026-07-31 wieczorem:** zastrzeżenie o korelacji było drukowane
bezwarunkowo, więc przy `verdict=no-freeze-seen` pod werdyktem „nie widziano
zamrożenia" stało zdanie „SQL uczestniczył w co najmniej jednym freeze/resume".
Sprzeczność, i to w stronę zmyślania dowodu. Wyszło dopiero na żywym guescie bez
SQL Servera — wszystkie fixture'y w testach miały zdarzenia, a asercja sprawdzała
tylko, czy notka istnieje. Notka jest teraz warunkowa, a przypadek zapięty
testem.

## 5. Testy — stan bieżący

Uruchomione lokalnie przy `55d33a2` (bez roota, bez ZFS, bez sieci). Pakiety
wskazane przez `./test/impact.sh` dla zmian tego dnia (`quiescehelper`, `join`,
`selfupdate` dla `deploy.sh`; `quiesce`, `statekey`, `tune` dla
`lib-zfs-snap.sh`) przebiegnięte ponownie przy tym commicie. **2026-08-06
(REV-046):** komplet suit wymaganych grafem dla zmiany w `deploy.sh`
przebiegnięty ponownie na diffie `a567328..HEAD` — `alertmail` 18/18 (nowa),
`draftscope` 26/26, `impact` 21/21, `join` 82/82, `joinmanifest` 10/10,
`joinremote` 8/8, `pause` 74/74, `quiescehelper` 119/119, `selfupdate` 28/28
(7 SKIP); zero błędów:

| Pakiet | Wynik | Zakres |
|---|---|---|
| `impact` | **56/56** | rozwiązywanie grafu testowego + `--verify` na prawdziwym drzewie. +15 (REV-20260807-068, **cztery rundy**): niezmiennik świeżości `PROJECT_STATUS.md` dotyczy **PROSPEKTYWNEGO DRZEWA COMMITA** — wpisów indeksu, czyli `<tryb> <obiekt> <ścieżka>`. Runda 1: SHA commita, niesprawdzalny przed własnym commitem. Runda 2 (odrzucona): skrót z drzewa roboczego, a `git commit` zapisuje indeks. Runda 3 (odrzucona): indeks, ale sam identyfikator obiektu — `git update-index --chmod=+x` zmienia prospektywny commit, nie ruszając bloba, więc bramka mówiła czysto, a commit zapisywał zmianę istotną dla zachowania (`100755`→`100644` na skrypcie produkcyjnym oznacza, że przestaje się uruchamiać). Runda 4: skrót po pełnym wpisie stage-0. Wszystko, na czym opiera się werdykt, pochodzi z indeksu: wpisy obserwowane, `PROJECT_STATUS.md` ze znacznikiem i `deps.conf`, który DEFINIUJE zbiór obserwowany. Gwarancja: po zielonym `--verify` zwykły `git commit` bez ruszania indeksu daje drzewo spełniające niezmiennik (`commit -a`, `commit <ścieżka>` i `--amend` ruszają indeks i są jawnie poza gwarancją). Każdy przypadek to osobne repozytorium git z KOPIĄ badanego skryptu, więc ta sama konstrukcja uruchamia kontrolę (`IMPACT_UNDER_TEST=`). Jeden przypadek z rundy 2 ODWRÓCONY: edycja niezainscenizowana nie wchodzi do commita, więc nie brudzi bramki. Kontrole: wobec `41bd774` padają 3 asercje (rozjazd indeks/status), wobec `c077b82` **dokładnie 1** (sam tryb) — reszta przechodzi, więc runda 4 jest addytywna | +10 (Etap 3, ZAMROŻENIE SILNIKA): `snapsend.sh`, `snapget.sh` i `lib-zfs-snap.sh` mają zapisaną linię bazową (wpis indeksu: tryb + obiekt, ten sam prymityw co niezmiennik świeżości) w `docs/project/ENGINE-FREEZE.md`. Zmiana zainscenizowana wobec pliku zamrożonego jest **odrzucana**, z nazwaniem pliku; zmiana samego trybu też. Odmowa ustępuje wyłącznie, gdy znacznik `unfreeze:` nazywa recenzję, która ISTNIEJE i nie jest jeszcze CLOSED — recenzja domknięta nie może autoryzować nowej pracy, bo już dostała odpowiedź. `--refreeze` przejmuje nową linię bazową z indeksu i **resetuje autoryzację**, żeby nie została wisieć. Plik spoza zamrożenia nie jest łapany. Świadomie NIE jest odporne na obejście: każdy może uruchomić `--refreeze` — usunięte jest wyłącznie zdarzenie CICHE, bo zmiana silnika wymaga teraz albo nazwanej recenzji, albo widocznego resetu w diffie. +11 (REV-20260808-070): zbior zamrozony to **piec** zatwierdzonych plikow (doszly `delsnaps.sh` i `check-snap-age.sh` — pierwsza wersja ZAWEZALA zatwierdzony kontrakt zamiast go zaimplementowac); autoryzacja jest ZWIAZANA ZE SCIEZKA — recenzja musi niesc recenzencki znacznik `authorizes-frozen:` wymieniajacy kazda zmieniona sciezke, bo wczesniej DOWOLNY otwarty watek przepuszczal dowolna zmiane silnika; `ENGINE-FREEZE.md` jest w grafie zaleznosci, bo to polityka wykonywalna, nie dokumentacja. Zbior zamrozony w testach jest WYPROWADZANY z dokumentu, nie spisany drugi raz |
| `gencron` | 58/58 (+2: golden `pair-label`, negatyw `pair-label-charset`) | parsowanie konfiguracji `gen-cron.sh`, golden + przypadki negatywne |
| `scope` | **34/34** | gramatyka pliku zakresu (REV-033 F2): sekcje `[dataset:]`, `include_parent`/`include_children`/`exclude`/`exclude_tree`, odmowy z numerem linii oraz decyzja „czy ten dataset jest w zakresie" |
| `cron` | **137/137** (+8 sekcja X: markery `ZFS-JOB BEGIN/END` w generowanej linii + fallback `mktemp`, znalezione na żywo 2026-08-17; +2 sekcja V: tryb pliku zamka, znaleziony na zywo 2026-08-06) | **Sekcja X — linia crona świadkiem własnego przebiegu.** Znalezione na żywo: 2026-08-09 tygodniowy job CT 103 na pve2 wystartował i nie zostawił śladu w ŻADNYM z trzech instrumentów naraz — nic w `cron.log`, brak rekordu w logu statystyk (więc nie doszedł do `emit_stats`, który odpala się nawet dla `skipped_lock`/`skipped_paused`), brak maila (rc nigdy nie było ≠ 0). Dataset przeszedł 14 dni bez kopii tygodniowej; jedynym powodem, dla którego ktokolwiek się dowiedział, było `check-snap-age` eskalujące do CRITICAL pięć dni później. Przyczyna strukturalna: wszystkie instrumenty żyją WEWNĄTRZ silnika, więc przebieg umierający zanim silnik naprawdę wystartuje jest niewidoczny dla wszystkich trzech jednocześnie — jedynym miejscem, które może to zaświadczyć, jest sama linia crona. `job_cron_line` emituje teraz `ZFS-JOB BEGIN <label>` przed komendą i `ZFS-JOB END <label> rc=$rc` po niej (BEGIN bez END = sygnatura tej klasy, `grep ZFS-JOB cron.log`); dwie linie na przebieg to świadomy koszt, bo sam kod wyjścia nie zapisałby 9 sierpnia niczego — awaria nastąpiła zanim jakikolwiek kod wyjścia zaistniał. `date -Is`, nie `date +FORMAT`: cron czyta nieescapowane `%` jako koniec komendy plus stdin, więc format string cicho ucinałby każdą linię (X5 to pinuje). Gołe `e=$(mktemp)` zastąpione fallbackiem obok logu: przy awarii `mktemp` `$e` było PUSTE, `2>"$e"` wywalało się i komenda nie wykonywała się w ogóle — mechanizm odtwarzający sygnaturę z 9 sierpnia co do joty, zmierzony w X6 (nowy kształt: silnik działa, oba markery) z pozytywną kontrolą X7 (stary kształt pod tą samą awarią: silnik nie rusza, log pusty). Linia monitora celowo NIEoznaczona (X3) — chodzi co 15 min i już raportuje stan przez ramiona rc. X0 pinuje, że config w ogóle coś wyemitował: pusty `$X_OUT` nie ma brakujących markerów, gołego `mktemp` ani zbłąkanego `%`, więc X1/X4/X5 przechodziły „zerem na zerze" — dokładnie to zrobiły przy pierwszym uruchomieniu kontroli przez `$GEN`. Czerwone na kodzie sprzed zmiany: X1, X2, X4, X6. **Reszta sekcji: `lib-cron.sh`** — jedyny pisarz crontaba: blok zastępowany w miejscu, wszystko poza nim bajt w bajt, markery zepsute odrzucane a nie naprawiane, `crontab(1)` zaślepiony (także tryb „przyjmuje zapis i przechowuje co innego"), zamek per-użytkownik z wymuszonym przeplotem dwóch procesów (REV-034 F2, +14), całościowy zapis `cron_replace_all` z odczytem zwrotnym (REV-034 F3, +9), jeden stały katalog blokad bez fallbacku per-caller (REV-035, +8, część SKIP na tej maszynie). Od REV-036 F5 biblioteka sama rozpoznaje zapauzowany kształt (`cron_fullcron_paused`/`cron_block_paused`) i odmawia przez `cron_paused_guard` w `cron_block_install_impl`/`cron_block_ensure_line_impl`/`cron_block_remove_impl` — ćwiczone przez `pause` (sekcje S/T), nie tu |
| `profiles` | **39/39** | granica profilu (REV-073, EGZEKWOWANA od REV-076). Regula „profil nie posiada topologii” zyla wylacznie w tej suicie: zaden kod produkcyjny nie odwolywal sie do `profiles/`, a `validate_fragment` bylo zdefiniowane wewnatrz pliku testowego. Do tego `templates.conf` bylo sprawdzane tylko pod katem ksztaltu naglowka, wiec profil mogl niesc `dst` i suita przechodzila. ZMIERZONE: dopisanie `dst = hdd/evil` do wbudowanego profilu zostawia STARA suite na 22/22, a poprawiona odmawia z podaniem pliku, linii i pola. Teraz `lib-profile.sh` jest walidatorem PRODUKCYJNYM, a suita wola jego — test nie moze poblogoslawic reguly, ktorej produkcja nie wykonuje. Schemat CONFIG v4 celowo NIE zostal zawezony: `src`/`dst` w `[template:]` sa legalne i pve0 uzywa tego produkcyjnie (`[template:vm_archive]` z `dst = hdd/backups/pve1`), bo szablon to konstrukcja WDROZENIA, a profil jest szablonem OGRANICZONYM. Nazwy pol nadal czytane z `--dump-fields`, nigdy powtorzone. +6 (REV-20260809-077 F1): `profile_validate_dir` ZAWODZILA OTWARCIE na niekompletnym profilu. Napisalem `[ -f "$dir/x" ] && ! validate`, co znaczy „jesli istnieje i padnie, zglos” — wiec BRAKUJACY artefakt zwracal sukces z granicy produkcyjnej, a pusty katalog walidowal sie czysto. Suita tego nie widziala, bo sprawdzala osobno, ze pliki wbudowanego profilu istnieja — inna wlasnosc, ktorej B1 by nie odziedziczyl. Profil to DOKLADNIE trzy artefakty i kompletnosc nalezy do tej samej granicy; przeniesienie jej do wolajacego odtworzyloby problem, ktory usunela REV-076. Kontrola wobec `bd9de5a`: **4 asercje padaja** (trzy brakujace artefakty i pusty katalog); brak katalogu i kontrola pozytywna przechodza tam tez i sa pokryciem regresyjnym |
| `reviewctl` | **92/0** (PROTOCOL V2) | maszyna stanów recenzji: stan jest **wyprowadzany** z nagłówków maszynowych w plikach recenzji/odpowiedzi/domknięcia, a `REVIEW_LEDGER.md` i `OPEN-THREADS.md` są generowane. Przypina macierz akceptacji z protokołu — w tym dwa przypadki, których ręcznie utrzymywana tabela nie mogłaby złapać: akceptacja wskazująca **inny** commit niż zgłoszony, i domknięcie bez akceptacji. Dwa realne błędy w samym generatorze wyszły z tych testów, w tym fail-open: stan liczony w podstawieniu poleceń gubił błędy w podpowłoce i zapisywał ledger z rc=0. +11 (REV-20260807-067): nagłówek niosący commit musi nazywać commit **osiągalny z opublikowanej gałęzi**. Osiągalność, nie rozwiązywalność — SHA, które wywołało tę recenzję, JEST prawdziwym commitem w klonie implementera, osieroconym przez przepisanie, więc `git cat-file -e` by je przepuścił, a recenzent i tak dostawał z GitHuba „No commit found". Przypadek sieroty buduje własny wiszący commit przez `git commit-tree`, zamiast polegać na tym, który akurat istnieje lokalnie. Trzy pola: `implementation`, `reviewed-implementation`, `closed-by`. Brak repozytorium git = odmowa, nie cisza. Kontrola negatywna wobec `2620824`: **6 nowych asercji pada, 22 strukturalne przechodzą**. +6 (REV-20260808-070 F4): STAN DOSTAW. Pod wyjatkiem direct-main implementer laduje pierwszy, ale marszruta byla wyprowadzana WYLACZNIE z artefaktow REV — wiec dostawa bez REV-a byla niewidzialna: `OPEN-THREADS.md` mowil, ze nie ma nic do zrobienia, gdy Etap 3 lezal na `main` bez werdyktu. Jedna linia `<!-- delivered: <sha> opis -->` w `docs/project/DELIVERIES.md` staje sie praca przypisana recenzentowi, az zostanie wyczyszczona JAWNIE: albo recenzent otworzy REV o tym SHA, albo zapisze `no-review-required`. SHA podlega tej samej regule osiagalnosci co SHA implementacji. +2: wada znaleziona przez UZYWANIE mechanizmu — czyszczenie dostawy zalezalo od tego, ze jakis REV AKTUALNIE wskazuje ten SHA, a `reviewed-implementation` jest wskaznikiem RUCHOMYM: recenzent przesuwa go na kazde kolejne zgloszenie. Gdy watek posunal sie dalej, dostawa wracala jako niezrecenzowana — i robilaby tak juz zawsze. „Zostalo zrecenzowane” to fakt o przeszlosci i musi byc zapisany jako fakt: znacznik `<!-- reviewed-by: <sha> REV-... -->` | **Sekcje X1/X2 (REV-125 F1, 2026-08-29)**: transakcja musi UDOWODNIC swoja migawke. `tx_guard` wykonywal `mkdir`/`cp`/dopisanie bez sprawdzania, a pisarz i tak mutowal zywy artefakt roli — nieudana migawka nie zostawiala nic pod `present/` ani pod `absent/`, wiec `tx_restore` nie mial pasujacej galezi, po cichu zostawial mutacje, a `tx_cleanup` kasowal katalog transakcji. Polecenie konczylo sie bledem, a werdykt recenzenta i tak przechodzil z CHANGES-REQUIRED na APPROVED z przesunietym wskaznikiem implementacji. Niezerowy kod wyjscia NIE jest ta wlasnoscia — wlasnoscia jest, ze po odmowie artefakt jest bajt w bajt ten sam. Sterowane stubem `cp` na PATH, tak jak odtworzyl to recenzent: prawdziwa transakcja, prawdziwy pisarz, prawdziwy generator, jedno wywolanie systemowe zepsute. X2 to druga strona tej samej granicy — gdy odtworzenie zawiedzie, kazda sciezka jest nazwana i kopia zapasowa ZOSTAJE, bo to jedyny caly egzemplarz faktow recenzenta. Kontrola: `reviewctl.sh` z kanonicznego `main` (identyczny z `e33b667`) wywraca szesc asercji, w tym te o bajtowej identycznosci — czyli odtwarza znalezisko.
| `monitor` | **24/24** (nowa, REV-056) | `check-snap-age.sh`: gdy nic nie pasuje do wzorca, wiek liczony z `creation` DATASETU przez tę samą drabinkę progów — świeży dataset czyta się OK, trzydniowy bez kopii nadal CRITICAL. Nieodczytany znacznik czasu to UNKNOWN, nigdy zmyślony wiek (dotyczy też ścieżki pasującego snapshotu, gdzie ten sam błąd siedział wcześniej). `zfs` to zaślepka w `PATH`, wszystkie czasy jako offset od jednego `NOW` — bez roota, bez ZFS-a, bez wyścigu z zegarem |
| `migrate` | **52/52** lokalnie i jako root na Linuksie, **54/54** jako konto delegowane (REV-057 + REV-058) | `gen-cron.sh --migrate-recursion`: wykrywanie przez ten sam przebieg opcji co walidator (`-m R-daily_` nietykane, `-Rv 3` rozdzielane), porównanie trójstronne z kontrolą jako pierwszą, zapis transakcyjny. Każdy przypadek odmowy sprawdza sumę kontrolną pliku źródłowego, nie tylko komunikat. Sekcja G (REV-058) odtwarza topologię root + konto delegowane zaślepkami `crontab`/`getent`/`id`: kontrola znajduje blok po linii `# Source:` u dowolnego użytkownika, a nieczytelny crontab, nieczytelna lista użytkowników i dwa pasujące bloki — odmawiają przed zapisem. D4 (nieudany zapis) wymaga nie-roota — pod rootem SKIP, bo root omija prawa katalogu |
| `cron2conf` | **27/0** | odtwarzanie configu z crontaba — round-trip przez prawdziwy `gen-cron.sh`, przypadki negatywne/ostrzegawcze. **Od 2026-08-17 dwa korpusy:** `fixtures/` w kształcie z markerami `ZFS-JOB` (bieżące wyjście generatora) i `fixtures-legacy/` w kształcie sprzed markerów. To drugie nie jest historią — wdrożenie to godzinowy `git pull`, więc host trzyma stary blok zarządzany aż coś uruchomi tam `--install`, i **cała flota jest dziś w tym stanie**. Narzędzie istnieje po to, żeby odbudować utracony config (pve2 tego raz potrzebował), więc odmowa na kształcie, który host faktycznie ma, psuła by je dokładnie w jedynej sytuacji, do której służy. `strip_witness_markers` w `cron2conf.sh` normalizuje nowy kształt do klasycznego przed parsowaniem; z markerów nie odzyskuje się NIC — etykieta i tak wraca z argumentów notify, więc są świadkiem, nie konfiguracją. Kontrola: wersja `cron2conf.sh` sprzed zmiany **odmawia wprost** (exit 1) na nowym kształcie zamiast cicho wyprodukować zły config, a `legacy/corpus-is-pre-marker` pilnuje, żeby marker nie wciekł do korpusu starego kształtu i nie zamienił tych siedmiu testów w porównanie nowego kształtu z samym sobą. **Fixture `paused-prune-bookmark` (2026-08-29)** przypina kształt, ktory pauza wprowadza na flote: linie prune z `-L` BEZ `-R`, oraz `-B -R -L <etykieta> -p <port>`. Parser nie znal ani `-L` przy `delsnaps`, ani flag ssh, a skutkiem nie bylo zgubione pole — `rest` zaczynal sie wtedy od `-L`, sprawdzenie cudzyslowu nie przechodzilo i narzedzie odrzucalo CALY crontab jako nierozpoznany. Jedna zapauzowana relacja na hoscie czynila je bezuzytecznym dla tego hosta, czyli dokladnie w miare wdrazania pauzy. Kontrola: `cron2conf.sh` z `main` odmawia na tym fixture | **Fixture `replica-removable` (2026-08-29)** przypina klamre nosnika: zadanie repliki nie zaczyna sie od sciezki do `snapsend.sh`, tylko od `( ... zfs-media-gate.sh attach ...`, wiec kazdy parser go odrzucal i narzedzie wywalalo CALY crontab. Ta sama klasa co `-L` tego samego dnia, tyle ze wada byla moja — wprowadzona razem z klamra. Kontrola: `cron2conf.sh` sprzed zmiany konczy na tym fixture bledem.
| `cleanrel` | **23/23** (nowa, 2026-08-20) | `clean-relationships.sh`: audyt i usuwanie śladów po relacjach. Każdy przypadek to kształt ZMIERZONY podczas rozbiórki 2026-08-20, nie wymyślony — bo narzędzie powstało dlatego, że ręczne sprzątanie coś przegapiło, więc jego testami są właśnie te rzeczy, które zostały przegapione. Pinuje trzy tożsamości jednej relacji (nazwa / adres / etykieta) i obie asymetrie, których nie widać w żadnym kodzie: `peers/` kluczowane dwojako przy `remove-client` usuwającym tylko wariant po adresie, oraz jeden z czterech plików klucza (`_alias_known_hosts`, ten podawany do `-k`) przeżywający usunięcie. Własności bezpieczeństwa jako testy: domyślnie tylko odczyt, usuwanie wymaga celu I `--yes`, LIVE wygrywa przy jakimkolwiek dowodzie, `--leave` przed ręcznym sprzątaniem, `rmdir` odmawiający przy niepustym katalogu, `id` a nie właściciel katalogu (recykling UID), `known_hosts` i datasety nazywane a nie kasowane, konto `zfsbackup` bez sufiksu wykluczone. Dwa przypadki dopisane po tym, jak test NA LABIE pokazał to, czego piaskownica nie mogła: duplikat w liście artefaktów (domyślna nazwa relacji JEST adresem, więc tożsamość i adres to ten sam ciąg) oraz mylące odmówienie `--leave` przy wyciekłym holdzie `zfssnapall_inflight` — jego treść zakłada trwający transfer, a przy wycieku nic nigdy się nie dokończy. W pełni w piaskownicy: każda ścieżka systemowa nadpisywalna, co jest jednocześnie tym, co rozluźnia wymóg roota i pozwala w ogóle przetestować ścieżkę usuwania | **Nagrobek i wykrywanie osieroconych danych (2026-08-20, po dyskusji z właścicielem):** purge zapisuje, JAKIE datasety należały do relacji, **zanim** cokolwiek usunie — bo to właśnie usuwany rekord był jedynym miejscem, które je nazywało (`hdd/lab4direct` przeżył swoją relację i po skasowaniu confa nic na hoście już go z niczym nie łączyło). Gdy relacja MA dane, a zapisu nie da się wykonać, purge **odmawia** — usunięcie ostatniej rzeczy nazywającej te dane, nie zostawiając niczego, co je nazywa, to dokładnie ta awaria, której nagrobek ma zapobiec. Audyt zgłasza datasety, o których nagrobek mówi, że należały do zniknionej relacji, a które nadal są na dysku — twierdzenie pochodzi z REKORDU, nigdy z kształtu nazwy. To jedyne miejsce w pliku wołające `zfs`, wyłącznie do odczytu, a jego brak jest pominięciem z uzasadnieniem, nie błędem. **Nie kasuje danych po żadnej stronie** — decyzja właściciela: na kolektorze kopia bywa jedynym egzemplarzem właśnie w chwili śmierci relacji, a `RUX_TARGET` jest wspólnym korzeniem wielu peerów, więc `destroy -r` na nim zabrałby cudze kopie. |
| `localbackup` | **50/50** (Faza 5 slice 1 + **slice 2 instalacja transakcyjna `da3e831`**; +6 REV-097; +2 REV-098; +5 REV-101; +5 REV-102 krok 2 lokalny; +4 REV-20260811-104 F1 niezależne szablony) | `zfs-backup.sh --source/--target` (bare, kanoniczne; `local-backup` alias) — wysokopoziomowy LOKALNY workflow source→target, wycinek PLANOWANIA (read-only, jak `restore --plan`). **REV-097:** F1 — źródło musi ISTNIEĆ w ZFS (`zfs list`, stub w teście), brakujące = twarda odmowa całości bez fallbacku; F2 — kandydat komponowany ADDYTYWNIE nad istniejącym CONFIG celu (istniejący job A zachowany bajt-w-bajt, wyrenderowany cron niesie A+B, overlap odmawia, brakujący CONFIG roszczony przez zainstalowany blok = fail-closed odmowa przez WSPÓLNY guard `assert_config_not_claimed_if_missing` wyodrębniony z `ensure_cron_config`); F3 — kanoniczne publiczne wejście to bare `--source/--target`, alias `local-backup` sięga tej samej logiki. **REV-098:** guard overlapu rozwija listy przez przecinki (`[prune:a,b,c]` — jak `config_datasets()`) i sprawdza każdego członka osobno; regresja pinuje odmowę przy overlapie z NIE-pierwszym członkiem `[prune:rpool/other,rpool/data]` + kontrolę że rozłączne żądanie obok tej samej wielościeżkowej sekcji dalej przechodzi (nie „każdy przecinek = konflikt"). Pinuje: odmowę nakładania w OBU kierunkach (cel pod źródłem, źródło pod celem, równe — backup nie może lądować w tym co backupuje; czysty test prefiksu ze `/`, odporny na `data` vs `database`), odmowę zdalnego (`:` = LOCAL only; `@host` łapie char-check), brak `--source`/`--target` i nieznany `--profile` odmawiają, kandydat CONFIG v4 renderuje się przez PRAWDZIWY `gen-cron.sh` z lokalnym `dst=` send (bez `:`) i znamespace'owanymi szablonami domyślnego profilu + drabiną GFS, jedna faktyczna nota przy wspólnej puli (nie zakaz), a planowanie NIE instaluje niczego (stub `crontab` w PATH nigdy nie wołany). Instalacja transakcyjna = kolejny wycinek. **REV-101:** multi-source WHAT — `--source=a,b,c` (i akumulacja powtórzonych flag, bez last-one-wins), każdy root walidowany (missing→refuse całości bez partiala), overlap parent/child w zbiorze odmawia, duplikat kanonizowany do jednego, po jednym `[dataset:root]` na root + jeden `[prune:target]`, gen-cron merge'uje w jedną comma-joined linię send (kształt jak golden `tiered.conf`). **REV-102 (krok 2, lokalny):** kandydat niesie teraz DWIE niezależne retencje — `[prune:root]` per root (ograniczenie `automated_hourly_` na ŹRÓDLE, drabina GFS z `prune.inc`) ORAZ `[prune:target]` (magazyn) — z tej samej drabiny przy CREATE, ale osobne edytowalne sekcje; wyrenderowany cron ma dwie osobne linie delsnaps (source i target scope), manualne snapshoty przeżywają (pattern `automated_`, nie `*`); kontrola out-of-band vs baza `5423518` = 0 sekcji source-prune (defekt), nowy kod = 1. **F2 (recenzja kroku 2):** source-prune był `recursive=yes` (→ `delsnaps -R`) mimo że `[dataset:root]` jest non-recursive — wchodził w dzieci (`root/vm-101`) i mógł kasować `automated_` spoza pokrycia relacji; poprawione na non-recursive (`delsnaps -G` bez `-R`, tylko nazwany dataset), test pinuje brak `-R` + kontrolę „dziecko przeżywa". **REV-104 F1:** source i target referowały TE SAME szablony (`profile__default__keep_*`) → edycja jednej strony zmieniała obie; teraz source dostaje odrębną rodzinę `profile__default__src_keep_*` (te same wartości przy CREATE, różna tożsamość, rename `__keep_`→`__src_keep_` namespace-agnostic). Testy: mutacja tylko source → zmiana source, target nietknięty (i odwrotnie); negctl: wspólna rodzina łączy obie (load-bearing). Remote-PULL/grant/migracja/real-ZFS = kroki 3–5 (REV-102 OPEN). **Faza 5 slice 2 (Gate 5) — WDROŻONA na main `da3e831`, DOSTAWA DO RECENZJI:** `--install` (+`--yes`) domyka planer do instalacji. Kolejność JEST kontraktem: podgląd → potwierdzenie → **SEED** → instalacja → odczyt zwrotny. Seed idzie PRZED cronem, bo właściwość akceptacyjna brzmi „nieudany/odrzucony seed nie zostawia nowego uprawnionego crona i da się ponowić"; instalacja przed seedem zostawiłaby godzinowe zadanie wskazujące na nienawiązaną relację. **Plan pozostaje domyślny** — `--install` to jawny czasownik, polecenie ze slice 1 działa bajt w bajt tak samo. Zero nowej orkiestracji: `show_activation_proposal`, cztery asercje przedinstalacyjne i `atomic_replace_and_install` to TE SAME helpery co `activate-client`. **Żadnego trwałego rekordu relacji lokalnej** — `CLIENTS_DIR` trzyma tylko klientów zdalnych, a zainstalowany CONFIG plus blok crona JUŻ są stanem; „active" to opis wyprowadzony, nie token. **Prefiks snapshotów seeda czytany z WYRENDEROWANEGO kandydata**, nie zaszyty — druga kopia prefiksu to mechanizm, którym seed po cichu rozjechałby się z linią crona, zakładając rodzinę snapshotów, której zainstalowany prune nigdy nie dopasuje; brak odczytu = odmowa, nie zgadywanie. Testy pinują KOLEJNOŚĆ (`SEED` przed `INSTALL`), nie samą obecność obu. **Dowód na żywym ZFS (pve1, 2026-08-12 16:02, crontab w piaskownicy):** 12 MB źródła zaseedowane realnym `snapsend`, dataset i snapshot celu powstały, zainstalowany blok niósł dokładnie trzy oczekiwane linie (send godzinowy, prune ŹRÓDŁA non-recursive, prune CELU rekurencyjny — podział retencji REV-102 nietknięty), istniejący `[defaults]` operatora przeżył, produkcyjny crontab nietknięty; lab skasowany. **Luka nazwana wprost:** transakcja crona nie była wykonana na PRAWDZIWYM spoolu — na obu żywych hostach oznaczałoby to zapis produkcyjnego crontaba; użyte helpery są identyczne z tymi, których `activate-client` używa produkcyjnie codziennie. **Druga luka, defekt w samej dostawie:** blok `Usage:` w `zfs-backup.sh` nadal opisuje tę komendę jako „plan/preview only", a `--install` i `--yes` nie są w nim wymienione — pomoc kłamie o zachowaniu narzędzia. Znalezione po zgłoszeniu `da3e831`; ŚWIADOMIE nienaprawione za plecami zgłoszonego SHA (protokół: nie modyfikuj zgłoszonej granicy akceptacyjnej, dopóki należy do recenzenta), **NAPRAWIONE** w REV-20260812-112 F1 (`0697f01`): blok `Usage:` opisuje teraz cały kontrakt w miejscu (bez `--install` planuje i nic nie instaluje; `--install` seeduje a potem instaluje crona transakcyjnie; `--yes|-y` pomija potwierdzenie). Dwie asercje, bo jedna nie łapie kształtu tego defektu: Usage MUSI wymieniać `--install` i `--yes/-y`, ORAZ stara bezwarunkowa fraza „plan/preview only" MUSI zniknąć — pomoc, która tylko dopisuje flagi i dalej nazywa komendę podglądową, przeszłaby pierwszą i nadal myliła. Druga asercja od razu się przydała: moje pierwsze sformułowanie zostawiło tę frazę w gałęzi warunkowej i test padł, więc przeredagowałem tekst zamiast rozluźniać test. `localbackup` **52/52**, `zfsbackup` 401/401 (pve1). **Defekt procesowy, nie produktowy:** REV-112 jest NIEWIDOCZNY dla `reviewctl` — plik recenzenta używa front-mattera YAML, a parser (`test/reviewctl.sh:41`) czyta formę `<!-- pole: wartość -->`, więc ledger nie ma wiersza 112 mimo `routing: Claude` w pliku. Trzecie dziś zamrożenie routingu przez nagłówek. Plik recenzenta nietknięty; moja odpowiedź celowo trzyma udokumentowaną formę. **Faza 5 slice 3 — WDROŻONA na main `04d79ae`, DOSTAWA DO RECENZJI:** `--target` można pominąć. Logika nie jest nowa — `propose_backup_target()` WYCIĄGNIĘTE z `setup-server` i współdzielone, żeby dwa miejsca nie rozjechały się w dwie różne idee tego, gdzie lądują backupy. Helper zwraca cel RAZEM z pochodzeniem i to ono niesie całą własność bezpieczeństwa: `default` (DEFAULT_TARGET z server.conf — świadoma wcześniejsza decyzja operatora) vs `heuristic` (zgadnięte z układu pul w tym przebiegu). Zgadnięty cel jest proponowany, ETYKIETOWANY jako zgadnięty i pokazany — ale **nie da się go zainstalować przez `--yes`**: operator albo nazywa cel, albo potwierdza interaktywnie. Zagrożenie z ekstrakcji obsłużone wprost: `die()` helpera przy niejednoznacznych pulach wykonuje się w podpowłoce podstawienia, więc wywołujący, który by je zpipe’ował lub zignorował status, przeleciałby przez odmowę z pustym celem — oba wywołania łapią `|| die`, a test pinuje, że odmowa jest TERMINALNA (plan nie powstaje). Kontrola dyskryminująca: ten sam pominięty `--target`, to samo `--yes`, różnica wyłącznie w pochodzeniu — guard odrzucający po prostu „`--yes` gdy pominięto `--target`" przeszedłby wszystko inne i padł na niej. `localbackup` **57/57**, `zfsbackup` 401/401 (pve1; druga suita to regresja na ekstrakcji z `setup-server`). **REV-20260812-112 ZAMKNIĘTY** (`0697f01`), **Gate 5 OSIĄGNIĘTA**, dostawa slice 3 wyczyszczona formalnie przez recenzenta (`reviewed-by: 04d79ae4… reviewer-clean-no-finding`). Bez ZFS/sieci/crontaba w suicie |
| `rux` | **23/23** (PR #26, 2026-08-16; +2 `--local-user=` fix znaleziony w RUX-4) | `zfs-backup.sh --source=/--target=/--mode=` — RUX, `docs/project/OWNER-REMOTE-DEPLOY-UX-REDUCTION-2026-08-12.md`. **`--local-user=NAME` znaleziony brakujący na żywym RUX-4** (pve2-metropolis, kolektor bez `server.conf` — `add-client`'s Batch B guard odmawiał, bo RUX nie miał jak przekazać konta delegowanego); dodany jako CREATE-time passthrough do `add-client`, bez `--local-user` odmowa dalej dochodzi do operatora nietknięta (pinowane osobno). Pins: lokalny `--source` (bez `:`) trafia do `cmd_local_backup` bajt w bajt; `--source=HOST:DATASET` parsuje backup (`--target` wymagany) i sync (`--mode=sync`, bez `--target`, żadnego drugiego `--target`); nieprawidłowa/dwuznaczna składnia `--source` odmawia; bez `--install` NIC nie dotyka żadnego z hostów (brak `CLIENTS_DIR`, brak wywołania `deploy.sh`); świeża relacja: `add-client` (z `--datasets=`/`--target` dla backup, `--mode=sync` dla sync) → `seed` → `activate`, w tej kolejności, RUX_SOURCE/TARGET/MODE zapisane w rekordzie klienta; pasująca istniejąca relacja jest WZNAWIANA (bez drugiego `add-client`); sprzeczne fakty (ten sam host, inny target/mode) odmawiają, nic nie wywołane; relacja NIE założona przez RUX (brak `RUX_SOURCE`) odmawia zamiast cicho przejąć; dwuznaczny host (dwie relacje) odmawia i prosi o `--name`, `--name=` rozstrzyga; `rux_verify_requested_scope` odmawia PRZED seedem, gdy to, co peer faktycznie przyznał (`PEER_SAVED_DATASETS`), nie pokrywa żądanego datasetu — sprawdzone zarówno dla braku pokrycia jak i dla pokrycia przez rodzica. Zero nowego silnika: cały orkiestracyjny ogon (`deploy_continue_lifecycle`) wydzielony z `cmd_deploy` i współdzielony z nim; `rux_verify_requested_scope` tylko CZYTA istniejący manifest peera, nigdy nie nadaje grantu. Suita pure/text: `deploy.sh`, `cmd_seed`, `cmd_activate` zaślepione — kontrakt to orkiestracja, nie ponowny dowód silnika `add-client`/`seed`/`activate` (ten już ma `zfsbackup`/`localbackup`/`zfsbackup-live-pair`). **RUX-4 LIVE-PROVEN 2026-08-16.** Prawdziwy trzyhostowy łańcuch (metropolis pve2↔pve1 + 11.x pve0↔pve1) nie jest osiągalny — dwa klastry są na osobnych VPN, brak wzajemnej trasy sieciowej (potwierdzone: `ping`/`ssh` z metropolis na 11.x = timeout). Zamiast tego dwa NIEZALEŻNE dowody dwuhostowe, każdy throwaway dataset, każdy sprzątnięty do zera po fakcie: **Kampania A (backup)** pve2-metropolis (kolektor) ← pve1-metropolis (źródło), `--source=192.168.28.9:hdd/ruxproof-src --target=hdd/ruxproof-target --local-user=zfsbackup --install` — realny `--join-remotely` (zablokowany raz przez osierocony manifest peera po dawnej relacji `i9b`, posprzątany `deploy.sh --leave=pve2` — TO był prawdziwy, nienazwany wcześniej dług techniczny, nie coś co ten dowód wytworzył), zawężenie draft-scope z pełnej listy 18 datasetów (w tym prawdziwa produkcja: `hdd/vm-disks`, `hdd/backups`, `rpool/data`) do WYŁĄCZNIE throwaway datasetu przed `--commit-scope`, realny transfer, **md5 identyczny ze źródłem**, zainstalowany cron dokładnie 4 linie jak przewidziane. **Kampania B (sync)** pve0 (kolektor) ← pve1 11.x (źródło), `--source=192.168.11.11:rpool/ruxproof-sync-src --mode=sync --local-user=zfsbackup --install` — `--join-remotely` przeszedł automatycznie za pierwszym razem, target = DOKŁADNIE ta sama ścieżka co źródło (`rpool/ruxproof-sync-src`, identity mapping potwierdzone), **md5 identyczny**. **Realne znalezisko silnika (nie defekt RUX, właściwość `deploy.sh --pair` sprzed tej zmiany):** próba trzeciej relacji (sync) do TEGO SAMEGO adresu peera co Kampania A (pve1-metropolis, 192.168.28.9) padła na `peer.conf carries both PEER_CONF_MODE and PEER_CONF_DATASETS` — jeden adres peera niesie JEDNĄ konfigurację parowania (klucz/rola/tryb/dataset), więc "jeden peer, dwie niezależne relacje (backup+sync)" nie jest dziś wspierane przez `deploy.sh --pair`, niezależnie od RUX; `rux_verify_requested_scope` poprawnie złapał niedopasowanie i odmówił PRZED seedem zamiast cicho zaseedować zły dataset — dlatego Kampania B poszła na inną parę hostów. Po dowodzie: `remove-client` na obu kolektorach, `deploy.sh --leave=LABEL` na obu źródłach (konta `zfsbackup-pve2`/`zfsbackup-pve0` usunięte, granty cofnięte), wszystkie 5 throwaway datasetów zniszczone, crontaby na pve0/pve2 **bajt-w-bajt identyczne** z zapisanym stanem sprzed testu (`diff` = 0), relacja produkcyjna `i9a` na pve1-metropolis nietknięta. `manual:rux-live-chain` w `test/deps.conf` zaktualizowany o wynik zamiast czystej deklaracji obowiązku |
| `restore` | **300/300** (NOWA suita, Faza 7; kolejne punkty kontrolne: slice 1 `70cd1ab` 13, slice 2 23, REV-114 staging 32, mapa planera + strategia `af59185` 38, REV-118 runda 1 `cffd1c4` 41, runda 2 `9187b35` 42, bramki ścieżki niszczącej 52, REV-119 świadome potwierdzenie + ogrodzenie zapisu `585d27f` 70, F1.1-F1.4 `d0aacdc` 77, resztka F1.2 `77df5b4` 81, runda 5 + WYKONANIE R-026 88, REV-120 bookmarki w zbiorze strat + test koncowy po tozsamosci 99, REV-120 runda 2 + REV-121 108) | `zfs-backup.sh restore --plan` — planer odtworzenia, **TYLKO ODCZYT**, nie dotyka niczego poza `zfs list`. Odpowiada na pytanie, na które dziś nikt nie umie odpowiedzieć: co by się odtworzyło. Który dataset, jakie snapshoty istnieją, **kiedy naprawdę powstały** i gdzie wylądowałoby odtworzenie. **Czas z właściwości ZFS `creation`, NIGDY z nazwy snapshota** — te dwie rzeczy rozjeżdżają się po przemianowaniu, przy ręcznym snapshocie naśladującym konwencję nazw albo przy złym zegarze, a plan czytający nazwę opowiada historyjkę zamiast faktu; przy różnicy >2 min planer mówi to głośno, bo sama rozbieżność jest informacją potrzebną przed wyborem punktu odtworzenia. Lokalizacje kopii wyprowadzane z zainstalowanego CONFIG-u (`[dataset:S]` + `dst=T` → kopia w `T/S`, jak pokazał żywy dowód slice 2; `[dataset:L]` + `src=` → `L` już JEST kopią), nic nie zgadywane. Świadomie BRAK czasownika odtwarzającego, tworzenia namespace i jakiegokolwiek zapisu ZFS — to slice 2 i 3 Fazy 7. Rdzeń suity to PARA, nie asercja: snapshot, którego nazwa kłamie, i taki, gdzie nazwa się zgadza — implementacja czytająca nazwę oblewa oba, a taka flagująca wszystko przechodzi pierwszy i oblewa drugi. Plus: nazwa bez znacznika czasu ma być listowana, nie flagowana, oraz asercja z zapisu wywołań, że każde `zfs` w każdym planie było `list`. Po drodze złapany błąd fixture’a (`mkcfg` pisał treść configu jako nazwę pliku po `shift`), przez który część asercji przechodziła z niewłaściwego powodu. **REV-20260812-113 F1 (`5ede32d`), IMPLEMENTED→recenzent:** recenzent zakwestionował, czy stub w ogóle dowodzi semantyki selektora `zfs list` — słusznie. ZMIERZONE na pve1/zfs-2.1.9 przed jakąkolwiek zmianą i **obie hipotezy upadły**: komenda bez selektora głębokości ZWRACA snapshot (rc=0, kontrola pozytywna), kontrola negatywna daje pustkę przy rc=0, a moje własne podejrzenie — że bez ograniczenia głębokości wciągnie snapshoty DZIECKA do planu rodzica — też okazało się fałszywe (wynik bajt w bajt jak przy `-d 1`). Do tego `listsnapshots=off` na puli nie blokuje ścieżki `-t snapshot`. Czyli defektu nie było. `-d 1` dodane mimo to: mogę zmierzyć dokładnie JEDNĄ wersję ZFS, a finding dotyczy polegania na domyślce w najważniejszym zapytaniu planera — nazwanie głębokości nic nie kosztuje i usuwa zależność od wersji zamiast mierzyć ją po każdym upgradzie. **Trwałą połową jest stub**, który teraz WYMAGA `-d 1` przy każdym listowaniu snapshotów: jego permisywność jest tym, co pozwoliło niesprawdzonemu selektorowi trafić na żywy host. **Faza 7 slice 2 — WDROŻONA na main `6f2dbff`, DOSTAWA DO RECENZJI:** `restore --dataset=X --snapshot=S` odtwarza do WYPROWADZONEGO namespace, nigdy pod oryginalną ścieżkę; niszczące zastąpienie zostaje osobnym czasownikiem, którego nie ma — nie flagą `--force`. **Akceptacja to OBIE przesłanki naraz** (uzgodnione z recenzentem przed kodem, R-005): pipeline send/recv musi się udać Z propagacją błędu ORAZ guid odtworzonego snapshota musi równać się źródłowemu. Zgodny guid po nieudanym pipeline to nie odtworzenie; czysty kod wyjścia przy innym guidzie to nie te dane. Test celuje dokładnie w tę szczelinę. **Semantyka nieudanej próby** (C-007), bez maszyny stanów: odmowa przy kolizji leci PIERWSZA, więc istniejący wcześniej dataset nigdy nie jest tknięty ani adoptowany; cokolwiek zostało po nieudanej próbie, utworzył ten przebieg — i ten przebieg to kasuje, więc ponowienie nie jest uwięzione za tą samą odmową; nieudane sprzątanie nie ogłasza sukcesu i nazywa dataset. **Trzy defekty, z czego dwa pokazują, że ani stub, ani żywy host same nie wystarczą:** (1) `zfs recv` NIE tworzy pośrednich rodziców — znalazł żywy przebieg, stub nie miał szans; (2) pętla szukająca najwyższego utworzonego przodka doszła do KORZENIA PULI, gdy `zfs list` zawiodło — i sprzątanie próbowałoby go zniszczyć; znalazł to stub, który NIE modelował istnienia puli, a na żywym hoście jest to strukturalnie niewidoczne, bo tam pętla zawsze staje poprawnie. Korzeń sprzątania jest teraz przyklejony do namespace restore i odmawia poza nim; (3) ścieżka docelowa obcinała pulę ze źródła, zlewając `rpool/data` i `tank/data` w jedno miejsce. `restore` **23/23**, `localbackup` 57/57, `zfsbackup` 401/401 (pve1). **Dowód end-to-end na żywo (pve1):** 8 MB odtworzone do namespace, guid potwierdzony POZA narzędziem, źródło nietknięte, ponowny przebieg odmówił przy kolizji i niczego nie zmienił, lab skasowany. **REV-20260812-114 F1 (`180de4c`), IMPLEMENTED→recenzent — defekt NISZCZĄCY, przyjęty bez zastrzeżeń:** moja inferencja „odmowa przy kolizji leci pierwsza, WIĘC to nasze" to TOCTOU. Gdyby inny aktor utworzył ścieżkę docelową między sprawdzeniem a `recv`, ścieżka awaryjna zrobiłaby `zfs destroy -r` na datasecie, którego ten przebieg nigdy nie utworzył. Kolejność w czasie nie jest dowodem własności. **Naprawa: staging + promocja.** Odbiór ląduje w datasecie o nazwie unikalnej dla próby (`restore-staging-<pid>-<epoch>-<random>`), więc jego skasowanie jest zawsze dowodliwie bezpieczne; dopiero zweryfikowany guidem wynik jest promowany przez `zfs rename`, który ODMAWIA istniejącego celu — czyli kolizja przegrywa wyścig przez atomowość samego ZFS-a, a nie przez sprawdzenie zrobione wcześniej i uznane za nadal prawdziwe. **Dwa świadome odwrócenia:** wczesne sprawdzenie kolizji ZOSTAJE, ale zdegradowane do ergonomicznego skrótu (nic nie dowodzi, nic od niego nie zależy); przodkowie namespace są tworzeni i JUŻ NIE kasowani — poprzednia wersja kasowała własne rusztowanie, a to jest dokładnie to sprzątanie, którego własności nie da się dowieść. **Dowód prymitywu na żywo (pve1):** `zfs rename` na istniejący cel → rc=1, źródło zostaje, cel nietknięty; na wolny → przechodzi. **Kontrola wyścigu jest w stubie**, bo wstrzyknięcia obcego datasetu między cudze sprawdzenie a cudzy `recv` nie da się odtworzyć na żywym hoście: obcy dataset przeżywa, żaden `destroy` go nie dotyka ani żadnego przodka go zawierającego, a własny staging i tak zostaje posprzątany. `restore` **32/32**, `localbackup` 57/57, `zfsbackup` 401/401. **Mapa planera (kontrakt R-013, `306cdba`), DOSTAWA DO RECENZJI:** `restore --plan` emituje teraz pełne `{dataset → snapshot, guid, creation, consistency}` — rozszerzenie istniejącego planera, nie nowy komponent. `guid` jedzie TYM SAMYM wywołaniem `zfs list` (`-o name,creation,guid`, sprawdzone na żywo przed zmianą: trzy pola, rc=0) zamiast `zfs get` na każdy punkt odtworzenia. `consistency` wyłącznie z zainstalowanego CONFIG-u — kontrakt zabrania wnioskowania z nazw, prefiksów, kształtu hierarchii i bliskich czasów, a powodem jest mój pomiar: dwa datasety na pve2 w różnych poddrzewach dzielą nazwę snapshota, a `creation` różni się o sekundę, bo jeden przebieg snapsend nazywa wszystko z jednego odczytu zegara. Wyjście FLAT mówi wprost, że to **frontier, a nie punkt w czasie**. **Test niosący tę zmianę:** te SAME dwa snapshoty dają `INDEPENDENT` pod płaskim CONFIG-iem i `ATOMIC` pod atomowym — werdykt jest więc dowodliwie kluczowany CONFIG-iem, a nie snapshotami, bo te są w obu przypadkach identyczne. **Podgląd domyślnej strategii (`af59185`, polityka właściciela z 2026-08-12):** planer liczy i pokazuje, co odtworzenie by ZROBIŁO — pięć werdyktów (źródła nie ma → FULL; źródło żywe bez wspólnego guida → FULL na żywe źródło, oznaczone jako niszczące; kopia z przodu → INKREMENT od bazy dowiedzionej GUID-em; źródło dokładnie w punkcie → brak pracy; źródło ZA punktem → SAM ROLLBACK z wymienieniem blokujących snapshotów). Źródło zdalne (pull) świadomie ODROCZONE, nie zgadywane. Żywy lab złapał tu realny błąd logiki: pierwsza wersja porównywała `base==latest` PRZED policzeniem blokad i mówiła „nic do zrobienia" źródłu, które miało dwa snapshoty za punktem — czyli ukrywała zniszczenie, które operator ma zatwierdzić. **REV-20260813-118 F1 (`cffd1c4`), IMPLEMENTED→recenzent:** zbiór blokad był zbiorem NAZW SNAPSHOTÓW, więc z definicji nie widział stanu, którego w żadnym snapshocie nie ma — danych zapisanych po ostatnim snapshocie źródła. To jedyna klasa stanu, którą odtworzenie niszczy NIEODWRACALNIE (cofnięty snapshot przynajmniej istniał). Podgląd czyta teraz `written` (własne rozliczenie ZFS-a, działa też dla ZVOL-i; `zfs diff` odrzucone — wymaga zamontowanego snapshota, nie działa dla wolumenów, chodzi cały dataset) i rozróżnia trzy stany: `0` = jedyny, który wolno pokazać jako „nic do zrobienia"/„nic nie blokuje"; `>0` = liczba bajtów wypisana, utrata nazwana, operacja niszcząca NAWET gdy żaden snapshot nie blokuje; odczyt nieudany = **klasyfikowany jako niszczący**, bo fail-open jest tu ciszą. Żywy lab (pve1, zfs-2.1.9) wymusił korektę samego faktu: po `dd` 4 MiB i `sync` `written` nadal pokazywało **0**, i dopiero `zpool sync` dało 4268032 — `written` odzwierciedla ostatni ZATWIERDZONY txg, a ta pula commituje raz na ~60 s, nie co 5 s. Czyste sformułowanie mówi więc „written=0 według ostatniego zatwierdzonego txg" i każe potwierdzić bezczynność źródła przed operacją niszczącą, zamiast obiecywać bezczynne źródło; wymuszenie commitu przez `zpool sync` odrzucone — to zapis na całą pulę, a ten czasownik reklamuje się jako tylko-odczyt. Test niosący zmianę to TEN SAM fixture co kontrola „no-op", różniący się WYŁĄCZNIE żywą deltą. **Runda 2 (`9187b35`), recenzent wyciągnął wniosek, przed którym się zatrzymałem:** skoro `written=0` może być nieaktualne o jeden txg, to NICZEGO nie dowodzi o stanie bieżącym, więc werdykt „nic do zrobienia" oparty na tej liczbie jest zgadywaniem w przebraniu faktu. Klasy są teraz DWIE, nie trzy: **dowiedziony brud** (`written>0` — bajty wypisane, utrata nazwana) i **niedowiedziony stan** (rozliczone zero ORAZ nieudany odczyt). Czasownik nie ma już żadnej odpowiedzi „no-op" — umie powiedzieć „nie rozliczono zmian", nie umie „zmian nie ma". Świadomie NIE zwinięte w jeden głośny werdykt niszczący: oba stany niedowiedzione niosą WŁASNY powód (`written=0` vs „odczyt nie dał liczby"), a stan niedowiedziony NIE twierdzi, że dane zostaną odrzucone — bo w tym stanie nikt nie wie, czy jakieś są; obie własności przypięte testami (zwinięcie klas przeszłoby pierwszy test, dlatego jest drugi). Kandydat na domknięcie luki txg nazwany i ODŁOŻONY: rozliczenie brudnych bajtów otwartego txg z `/proc/spl/kstat/zfs/<pula>/txgs` byłoby realnym dowodem bezczynności, ale to założenie Linux/OpenZFS-kstat, a nie właściwość ZFS — czyli dokładnie to „nowe założenie środowiskowe", które wymaga szerszej kampanii na żywo. **Bramki ścieżki niszczącej — WEWNĘTRZNE (`restore_replace_internal`), zero wykonania, zero publicznej gramatyki (R-018/R-019: właściciel ustala CLI, więc flaga nie powstaje; testy wołają funkcję wprost):** relacja rozwiązywana przez nowe wspólne `restore_relations()` (jedna instancja prawdy — podgląd i czasownik niszczący nie mogą mieć różnych pomysłów, gdzie leży kopia), odmowa przy braku `--dataset`, dataset spoza relacji, wielu dopasowaniach (CONFIG sam ze sobą sprzeczny — nie zgadujemy z której relacji odtwarzać), relacji **ATOMIC** (poddrzewo w jednym punkcie czasu, a ten czasownik odtwarza JEDEN dataset — cicha degradacja tej własności byłaby gorsza niż brak funkcji), źródle zdalnym, kopii bez snapshotów oraz braku bazy dowiedzionej GUID-em (→ „PEŁNE zastąpienie", inny mechanizm, nie udawany przyrostem). `restore_plan_strategy` publikuje teraz werdykt także jako FAKTY (`RESTORE_STRATEGY`/`RESTORE_BASE_GUID`/`RESTORE_TARGET_SNAP`/`RESTORE_BLOCKERS`), więc kod rozgałęzia się na dokładnie tej kalkulacji, którą operator zobaczył — nie na drugiej, własnej. Kontrakt i jedyny realny kompromis (zachowanie stanu rozbieżnego vs tani przyrost) opisane w `docs/design/destructive-recovery-contract.md`; R-017 rozstrzygnął go na wersję zero-wyborową. **REV-20260813-119 F1 (`585d27f`), IMPLEMENTED→recenzent — dwie rundy, obie o TEJ SAMEJ własności: zgoda ma być świadoma i ma zostać prawdziwa.** Runda 1: moja kolejność brzmiała „potwierdź, potem zmierz", a REV-118 (mój własny finding trzy commity wcześniej) dowodzi, że tak się nie da — `written` na żywym datasecie spóźnia się o txg, więc podgląd tylko-do-odczytu nie umie podać dokładnej straty, więc zgoda oparta na nim jest zgodą na zbiór, którego nikt nie zmierzył. Ścieżka robi teraz **techniczny snapshot PRZED wypisaniem strat** i liczy z niego: snapshot jest punktem zatwierdzonym, więc delta jest faktem. To **odwraca** wcześniejszą regułę „nic nie mutuje, nawet snapshotu" — świadomie, bo to właśnie ta mutacja kupuje tę własność. Zgodnie z R-017 nigdzie nie jest nazywany kopią bezpieczeństwa (rollback go niszczy); tekst mówi POMIAR, a test pilnuje sformułowania. Po zgodzie: drugi techniczny snapshot i `written` MIĘDZY nimi — rozliczenie dwóch punktów zatwierdzonych, które się nie spóźnia — plus wykrycie obcego snapshota w oknie; cokolwiek z tego = stan przyszedł po zatwierdzeniu → **nic nie ginie**, oba snapshoty znikają, komunikat mówi CO doszło. Odczyt nieczytelny liczy się jako przybycie. **Runda 2 — OGRODZENIE ZAPISU**, bo recenzent słusznie odmówił przyjęcia sprawdzenia, które dowodzi tylko przeszłości: między sprawdzeniem a zniszczeniem źródło dalej przyjmuje zapisy. Ogrodzeniem jest `readonly=on` — jedyny mechanizm ZFS realnie odmawiający zapisów userland (filesystemy i ZVOL-e), nieblokujący tego, czego ta ścieżka potrzebuje (snapshot/rollback/recv to nie są zapisy userland). **Idzie w górę PRZED snapshotem granicznym** (test pilnuje kolejności — postawione po sprawdzeniu przesuwałoby tę samą dziurę o krok dalej). Przywracanie dokładne, nie wygodne: wartość **dziedziczona** wraca przez `zfs inherit`, nie przez lokalne `set` które dziś czyta się tak samo a jutro rozjedzie z rodzicem; źródło, które **już było** `readonly=on`, takie zostaje (przywracanie „off" jako typowego przypadku skasowałoby świadome ustawienie) — to jest para dyskryminująca. Fail-closed w obie strony: ogrodzenia nie da się postawić → odmowa przebiegu; nie da się zdjąć → **głośny błąd z komendą do ręcznego cofnięcia**, bo produkcyjny dataset zostawiony w readonly to inna awaria niż ta, po którą wołano narzędzie. Bez flagi polityki (R-020: to mechanizm, nie wybór). Ryzyka nazwane wprost w odpowiedzi: ogrodzenie to odmowa ZFS a NIE zamek (root może je zdjąć), zapis przyjęty przed jego postawieniem nie jest cofany (łapie go dopiero granica — dlatego oba mechanizmy istnieją), a ogrodzenie ZVOL-a używanego przez DZIAŁAJĄCY guest da mu błędy I/O. **Runda 3 — cztery resztki (`d0aacdc`), wszystkie tego samego rodzaju: intencja dobra, mechanizm zły.** *F1.1*: „co jest nowe" liczone z POZYCJI w liście sortowanej po `creation`, a `creation` ma rozdzielczość sekundy — więc to nie jest porządek totalny i intruz z tej samej sekundy mógł posortować się PRZED snapshotem podglądowym i wypaść ze zbioru; do tego pośredni snapshot skraca interwał mierzony przez `written`, więc przebieg mógł wrócić zielony mierząc nie to okno. Teraz **różnica zbiorów nazw**, zero kolejności. *F1.2*: odczyt starego stanu i mutacja były jedną funkcją, więc nieudana weryfikacja zwracała porażkę bez zapisanego stanu i mogła zostawić produkcyjne źródło w readonly; rozdzielone (`restore_fence_capture` tylko czyta, `restore_fence_raise` tylko zmienia), a po nieudanym podniesieniu cofnięcie leci BEZWARUNKOWO, bo `set` mógł przejść i paść dopiero weryfikacja. *F1.3*: właściwość o pochodzeniu `received` przywracana przez `zfs set` staje się lokalnym override'em — dobra wartość, zły stan; teraz `received` → `zfs inherit -S`, `local` → `set`, dziedziczone → `inherit`, plus odczyt zwrotny odrzucający zamianę nie-lokalnego pochodzenia na lokalne. *F1.4*: sprzątanie ostrzegało i zwracało SUKCES, więc wywołujący mówili operatorowi, że źródło jest nietknięte, gdy leżał na nim snapshot tego przebiegu; teraz zwraca status, a jedno wyjście rozdziela dwa twierdzenia („nic nie zniszczono" vs „źródło jest jak przed poleceniem"). Kontrola przy F1.4 pilnuje, że przy UDANYM sprzątaniu wolno powiedzieć, że źródło jest nietknięte. Fixture do F1.1 miał tę samą wadę co kod: wstrzykiwał intruza przy snapshocie PODGLĄDOWYM, co przy różnicy zbiorów jest poprawnie ignorowane — przesunięty na snapshot graniczny. **Runda 4 — resztka F1.2 (`77df5b4`): ta sama wada co F1.4, popełniona warstwę WYŻEJ w tym samym commicie.** Sprzątanie snapshotów zaczęło meldować status uczciwie, ale cofanie `readonly` dalej ginęło w `|| true` na każdej ścieżce po mutacji — a funkcja kończąca, widząc usunięte snapshoty, mówiła operatorowi, że źródło jest dokładnie jak przed poleceniem, podczas gdy leżało w readonly. Twierdzenie o nietkniętym źródle wymaga teraz **OBU** faktów naraz (przywrócona właściwość ORAZ usunięte snapshoty), stan ogrodzenia jest **parametrem** wywołania (wywołujący nie może go pominąć ani „zapomnieć"), a raport wymienia każdą pozostałość osobno — jedno zbiorcze zdanie wysłałoby operatora do naprawienia połowy. Starsza asercja poszła na czerwono ze słusznego powodu i została **przepisana, nie rozluźniona**: pinowała dosłowne zdanie, które ta zmiana zastąpiła wspólnym raportem, więc teraz pinuje kontrakt (niezerowy kod, wymieniona `readonly` z komendą naprawczą, brak twierdzenia o nietkniętym źródle) — taka asercja łamie się tylko wtedy, gdy własność naprawdę znika. **WYKONANIE — wewnętrzny wycinek po zamknięciu REV-119 (R-026), zero publicznej gramatyki:** `restore_execute()` wykonuje krok niszczący, na który wszystkie poprzednie wycinki tylko się przygotowywały. Jeden zakotwiczony GUID-em rollback jest prymitywem dla każdej osiągalnej strategii — `rollback`/`discard-live`/`unproven` cofają źródło do punktu odtworzenia (`-r` usuwa dokładnie to, co nowsze od bazy: zatwierdzone blokady plus techniczne snapshoty tego przebiegu), a `increment` po tym rollbacku dobiera deltę jednym `zfs send -i | zfs recv`. **Akceptacja przez GUID, nie przez kod wyjścia** (C-006/C-007): najnowszy snapshot źródła musi nieść `RESTORE_TARGET_GUID`, inaczej przebieg zawiódł mimo czystych kodów. Nazwy snapshotów bazy (kopii i źródła) są publikowane jako fakty (`RESTORE_COPY_BASE_SNAP`/`RESTORE_SRC_BASE_SNAP`) przez `restore_plan_strategy`, więc kod działa na tej samej kalkulacji, którą operator zobaczył. **Semantyka porażki jest rozdzielona na dwa kody:** `1` = przed rollbackiem (wszystkie warunki wstępne sprawdzone najpierw, rollback atomowy), więc NIC nie zniszczono i wolno powiedzieć „źródło jak przed poleceniem"; `2` = po rollbacku (nieudany transfer albo niezgodny GUID), więc źródło jest częściowo zmienione i to jest powiedziane wprost, nigdy nie udając nietkniętego. Ogrodzenie schodzi na końcu; nieudane zdjęcie po UDANYM odtworzeniu jest głośne, osobne i nie podważa samego odtworzenia. **Ogrodzenie NIE blokuje rollbacku ani odbioru przyrostowego — zweryfikowane na żywo (pve0/zfs-2.1.9) przed napisaniem kodu:** oba działają na `readonly=on`, bo to nie są zapisy userland. Stub testowy modeluje `rollback`/`send`/`recv` na tym samym magazynie wierszy co odczyty, więc asercje pinują EFEKT (blokady zniknęły, cel dojechał, GUID się zgadza), nie samo wywołanie komendy; audyt całej suity wylicza dozwolony zbiór wywołań `zfs` (odczyty, techniczne snapshoty tego przebiegu, ogrodzenie i trzy prymitywy wykonawcze) i łapie każde inne jako obce. **Dowód end-to-end na ŻYWYM ZFS (pve0, 2026-08-14, throwaway `hdd/r119live`):** increment (delta realnie przeniesiona, dane wróciły, GUID celu), rollback (blokady `s2`/`s3` zniszczone, 57344 B, źródło na bazie), discard-live (4268032 B zatwierdzonych żywych zapisów odrzuconych) — każdy z GUID potwierdzonym poza narzędziem, ogrodzeniem w dół i brakiem pozostałości. **REV-20260814-120 (dwa P1, IMPLEMENTED -> recenzent) — ten sam błąd popełniony o dwóch różnych obiektach.** *F1: `zfs rollback -r` kasuje też BOOKMARKI.* Zmierzone na pve0 PRZED zmianą kodu: rollback do `@s1` przy `#bm1/#bm2/#bm3` zostawił samo `#bm1` — to, którego `createtxg` RÓWNA SIĘ celowi. Planer wyliczał wyłącznie snapshoty, więc prymityw poszerzał zatwierdzony zbiór w chwili wykonania: operator zatwierdzał zbiór bez bookmarka, a ginął też bookmark. Bookmark nie zajmuje miejsca (więc nie było go widać w bajtach), ale jest punktem zaczepienia przyszłego wysyłania przyrostowego — projekt ma na tym oparty fallback. Naprawa: baza źródła rozwiązywana po GUID-zie RAZEM z jej `createtxg` (`RESTORE_SRC_BASE_TXG`), zbiór blokad liczony jako `createtxg > baza` dla snapshotów I bookmarków — co przy okazji usuwa DRUGĄ instancję defektu F2, bo blokady liczyło się dotąd z POZYCJI w liście sortowanej po `creation`; nieudany odczyt listy = zbiór NIEDOWIEDZIONY i odmowa przed pierwszą mutacją (zmierzone: dataset bez bookmarków listuje PUSTO przy rc=0, więc „nie ma" i „nie dało się odczytać" są rozróżnialne i nie wolno ich zlepić); bookmarki wypisane w mierzonym zbiorze strat; granica zatwierdzenia rewaliduje je jak snapshoty (ogrodzenie `readonly=on` ich NIE blokuje — `zfs bookmark` to nie zapis userland, tak samo jak `zfs snapshot`); a **tuż przed komendą niszczącą zbiór jest mierzony ponownie i musi być DOKŁADNIE równy zatwierdzonemu** (blokady + bookmarki + dwa techniczne snapshoty TEGO przebiegu, przekazane wprost przez wywołującego) — różnica w którąkolwiek stronę to odmowa PRZED rollbackiem, czyli czyste „nic nie zniszczono". *F2: test końcowy liczony z pozycji w liście.* `zfs list -s creation | tail -1` nie mówi, który snapshot jest głową — mówi, który z dwóch równych wierszy ZFS akurat wypisał ostatni. Teraz DWA fakty, żaden pozycyjny: snapshot o `RESTORE_TARGET_GUID` jest na źródle (dokładnie jeden wiersz) ORAZ nic na źródle nie jest od niego nowsze — snapshot ani bookmark, po `createtxg`. Nieudany odczyt po operacji to porażka `2`, nie sukces. **Zasięg F2 nazwany uczciwie:** bazowej implementacji NIE udało się wywrócić end-to-end na żywym hoście — zmierzone, że na zfs-2.1.9 remis na `creation` wraca w kolejności `createtxg` (próba z odwróconymi nazwami wyklucza sortowanie po nazwie), więc przy jednym zegarze `tail -1` jest przypadkowo poprawny. Rozjazd obu porządków wymaga zegara DRUGIEGO hosta, a to jest zmierzony, normalny mechanizm: `zfs recv` zachowuje `creation` NADAWCY i nadaje NOWY lokalny `createtxg` (donor 42609601 -> odbiorca 42609603, `creation` identyczne). Skew zegara na produkcji nie był fabrykowany; zamiast tego w response jest substytut po tożsamości (obie połowy nowego testu uruchomione na żywej parze z tej samej sekundy) plus przypadki celowane w suicie, gdzie remis da się ustawić niekorzystnie. Kontrola kompletności (`rollbackleak`): rollback, który zwraca 0 i zostawia coś nowszego, jest łapany jako porażka PO zniszczeniu — bez niej samo „czy GUID celu istnieje" przeszłoby te testy. **Ryzyko nazwane wprost:** WYBÓR punktu odtworzenia na kopii dalej używa `tail -1` z listy po `creation` — ta sama niedowodliwa reguła krok wcześniej; świadomie NIE ruszona, bo na kopii `creation` to „kiedy dane powstały" (sens polityki właściciela), a `createtxg` to tylko kolejność przyjścia — zamiana byłaby zmianą POLITYKI, nie mechanizmu, i należy do osobnego findingu. Dowód na żywo (pve0, throwaway `hdd/r120src`/`hdd/r120bak`, skasowane): odmowa zostawia `@blk1`, `#bmnew` i `#bmold` nietknięte i zdejmuje ogrodzenie; zgoda kasuje `@blk1` i `#bmnew`, ZOSTAWIA `#bmold`, wraca na `@base`, GUID potwierdzony, ogrodzenie w dół, zero pozostałości. Kontrola dyskryminująca: nowa suita puszczona na implementacji z REV-119 (`ZB=...`) daje **91/8**. **REV-120 RUNDA 2 (P1) — pomiar nie wystarczy, musi wystarczyć kształt polecenia.** Recenzent nie przyjął rundy 1: zbiór był mierzony tuż przed zniszczeniem, ale zniszczeniem dalej był `zfs rollback -r`, który sam decyduje, co jest nowsze od bazy — więc bookmark powstały w mikrosekundach po pomiarze ginął niezatwierdzony. To była resztka, którą sam nazwałem w response; nazwanie jej nie jest jej usunięciem. Teraz każde wywołanie niszczące jest jednego z dwóch rodzajów: `zfs destroy` nazywający zatwierdzone obiekty WPROST (nie sięgnie po nic innego), albo **nierekurencyjny** `zfs rollback`, który sam odmawia przy czymkolwiek nowszym. Zmierzone identycznie na 2.1.9 (pve0, wersja floty) i 2.2.2: `zfs destroy ds@a,b,c` usuwa wiele snapshotów JEDNYM wywołaniem (więc gros zbioru strat zachowuje atomowość, a typowa awaria — hold, zajęty dataset — nadal pada zanim cokolwiek zniknie); dla bookmarków składnia z przecinkiem NIE działa (`bookmark 'ds#b1,b2' does not exist`), więc idą pojedynczo; nierekurencyjny rollback przy nowszym bookmarku odmawia, WYMIENIA winowajców i nie niszczy niczego — plik zapisany na żywo przeżył. **Cena nazwana wprost:** zniszczenie zaczyna się przed rollbackiem, więc spóźniony obiekt to porażka CZĘŚCIOWA (2), nie czysta odmowa (1) — runda 1 miała ten kompromis odwrotnie: trzymała ładną historię porażki i płaciła za nią danymi, na których utratę nikt się nie zgodził. Stub odmawia `-r` w ogóle, więc przywrócenie rekurencyjnego rollbacku zapala każdą asercję niszczącą zamiast po cichu wrócić do wyścigu. Wymagana kontrola dyskryminująca wstrzykuje bookmark PO ostatniej walidacji egzekutora i PRZED poleceniami niszczącymi — w okno, którego nic już nie obserwuje — i pilnuje trzech rzeczy naraz: spóźniony bookmark PRZEŻYŁ, zatwierdzone obiekty JUŻ zniknęły, a przebieg melduje porażkę częściową i nigdy nie twierdzi, że zatwierdzone zniszczenie się dokonało. `EX6` przepisany, nie rozluźniony: „rollback padł" nie znaczy już „nic nie zniszczono", więc granica, którą pinował, się przesunęła — jest teraz parą (padający all-or-none destroy zbioru: nic nie zniszczono, wolno twierdzić o nietkniętym źródle / padający po nim rollback: częściowa, twierdzić nie wolno). **REV-20260814-121 (P1, osobny REV z mojego własnego zgłoszenia w response rundy 1):** domyślny punkt docelowy brany był z `tail -1` listy po `creation`. Oś ZOSTAJE `creation` (czas powstania danych = sens polityki właściciela; `createtxg` na kopii to kolejność PRZYJŚCIA, więc podmiana byłaby zmianą polityki, nie mechanizmu) — zmienia się to, co się dzieje, gdy oś nie rozstrzyga: przy wspólnym maksimum czasownik ODMAWIA i wymienia kandydatów. Kontrole: unikalne maksimum dalej wybiera oczekiwany GUID, remis PONIŻEJ maksimum nie jest dwuznacznością (inaczej czasownik przestałby działać na każdej żywej kopii), nieczytelne czasy to też dwuznaczność, a osobna asercja czyta ŹRÓDŁO planera i pilnuje, że `tail -1` w wyborze punktu już nie ma. **Dowód F2 domknięty na żywo (2026-08-14):** tego, czego nie dało się odtworzyć na jednym hoście, dowiodła jednorazowa VM-ka z własnym zegarem (Ubuntu 24.04, zfs-2.2.2, plikowy pool, skasowana po dowodzie). Zegar dawcy przesunięty o 2 h do przodu, snapshot, zegar cofnięty, `send | recv` — odbiorca zachował `creation` NADAWCY i dostał NOWY lokalny `createtxg`, więc porządek czasu i porządek transakcji na jednym datasecie się rozjechały. Na tym labie implementacja z REV-119 zgłosiła **`weryfikacja GUID zawiodla` i „źródło zostało częściowo zmienione" dla POPRAWNEGO odtworzenia** (źródło stało na punkcie docelowym, blokada usunięta); obecna na identycznym labie melduje sukces i stan się zgadza. To zamyka jedyne zdanie „nie dało się odtworzyć na dostępnym sprzęcie" z poprzedniej rundy. Suita jest pure/text ze stubem; dowód wykonania jest na żywo, bo semantyka zależy od prawdziwego ZFS (R-026: bez samych stubów). Bez ZFS/sieci/crontaba w suicie |
| `configexamples` | **24/24** (nowa REV-20260810-094; +3 total-coverage guard REV-20260810-096) | runnable przykłady `docs/examples/*.conf` renderowane prawdziwym `gen-cron.sh -c`. Warstwa 1: każdy przykład (także przyszły) musi się sparsować (exit 0). Warstwa 2: przypina semantyczne własności linii, których każdy przykład uczy — niezależne liczniki `-H24`/`-D14` i BRAK drabiny GFS, per-dataset `-q agent`/`-q sync` z trzema nierozłączonymi liniami send, krótka lokalna `-H48` vs magazyn `-D90`, monitor-carrier `prune=no` emitujący `check-snap-age` bez drugiej linii `delsnaps` na tym samym zakresie, linia prune bookmarków. Krawędzie grafu: zmiana `gen-cron.sh` LUB `docs/examples/*.conf` selektuje tę suitę, suita selektuje samą siebie. Kontrola negatywna wewnątrz suity (mutacja `keep 24→99`) plus zweryfikowane osobno: cała suita wychodzi rc=1 gdy prawdziwy przykład zdryfuje. Warstwa 3 (REV-096): meta-guard trzymający rejestr `COVERED` DOKŁADNIE równym zbiorowi `docs/examples/*.conf` — dodanie 5. przykładu bez rejestracji semantyki albo wpis rejestru bez pliku = FAIL (dowiedzione: realny 5. `.conf` bez rejestracji wywala suitę). Dwie kontrole negatywne na FIXTURZE (katalog tymczasowy z nierejestrowanym `.conf`; rejestr z nazwą bez pliku), bez ruszania realnego drzewa |
| `quiesce` | **161/161** | księgowanie `-q`: własność guesta, deduplikacja, trasa uprzywilejowana lokalnej ścieżki (+10) odmowa zamiast degradacji (+14, REV-023) **oraz okno zamrożenia jako termin (+15, REV-024)** |
| `tune` | 48/48 | cache autotune `-A` |
| `rerun` | **16/16** (harness sourcuje `lib-backup-common.sh` od 2026-09-03) | idempotentne ponowienie czterokomendowego przeplywu (kontrakt #9: „rerun resumes from durable state"). `add-client` i `seed` padaly na istniejacej relacji, wiec powtorzenie udokumentowanej sekwencji dawalo `rc=1` dwa razy, a operator musial wiedziec, ktore kroki pominac — to nie jest wznowienie. Przypiete obie polowy: IDENTYCZNE ponowienie to no-op, ponowienie z innym hostem, **portem**, targetem lub **jawnie podanym kontem** nadal odmawia (recenzja wykazala, ze pierwsza wersja przepuszczala rozny port i jawne `--local-user=root` — oba przypadki maja teraz dyskryminatory), a `seed` nadal odmawia w stanach, ktore nie sa ukonczonym seedem. Kontrola negatywna wobec builda sprzed poprawki: **4 asercje padaja**; wobec builda po pierwszej poprawce padaja **2** (port i jawne konto). Osobno przypieta sciezka zapasowa: rekord sprzed `CREATED_ENDPOINT` bierze port z manifestu parowania, a endpoint, ktorego nie da sie potwierdzic, **nie** jest no-opem |
| `stagger` | **13/13** | rozrzut relacji po tarczy zegara: ktora minute dostaje nowa relacja i ktore minuty sa juz zajete. Dwa znaleziska recenzji przypiete dyskryminatorami: kolektor zajetych minut przepuszczal tylko `^[0-9]+$`, wiec poprawny job `*/15` byl NIEWIDZIALNY i relacja ladowala na nim; a gole `*` w pierwszej wersji ekspandera bylo rozwijane przez GLOB do nazw plikow, wiec najczestszy wildcard po cichu dawal pusto. Kontrola negatywna wobec builda sprzed poprawki: **8 asercji pada**, 5 przechodzi |
| `linkfields` | **49/49** | pola LACZA — `bandwidth`, `compression`, `cipher` — wyjete z worka `flags`. Pinuje, ze kazde renderuje DOKLADNIE ten token, ktory operator wpisalby recznie (asercja renderuje oba zapisy i porownuje wywolanie silnika), ze ta sama opcja przychodzaca i z `flags`, i z pola jest ODRZUCANA zamiast scalana, oraz ze kontrola dubla czyta `flags` tak jak getopts w obie strony: zbundlowane `-eb 2M` jest lapane, a argument `-m b-daily_` nie. Przypieta tez pulapka kolejnosci: jawny kompresor musi zatrzymac `-A`, wiec pola renderuja sie PRZED autotune, z kontrola, ze bez kompresora `-A` nadal sie pojawia. Kontrola negatywna wbudowana w kazdy przebieg: poprzedni `gen-cron.sh` musi odrzucic wszystkie trzy pola jako nieznane |
| `scopefields` | **35/35** | pola ZAKRESU — `passive`, `exclude_family`, `exclude_child_<n>` — druga polowa rozbicia, ktore zaczely pola LACZA. W `flags` zostawala TOZSAMOSC (`-K/-k/-O/-p`) plus trzy DECYZJE o tym, co relacja bierze ze zrodla: czy sama stempluje snapshoty, czy adoptuje cudza rodzine (`-e`), ktorych rodzin nie adoptuje (`-E`), ktorych dzieci nie bierze (`-X`). Pinuje, ze nazwane pola renderuja te same tokeny w tej samej KOLEJNOSCI co zapis reczny (kolejnosc, bo przestawiony `flags` to szum w kazdym `crontab diff`), ze ta sama opcja z `flags` i z pola jest ODRZUCANA, oraz ze `passive = no` obok recznego `-e` tez jest odrzucane: `no` nie renderuje nic, wiec nie ma dubla, jest tylko config czytajacy odwrotnie, niz dziala. `exclude_child_<n>` jest NUMEROWANE, bo wartosc to REGEX i moze zawierac kazdy separator, ktory wybralaby lista; dziura w numeracji jest odrzucana zamiast po cichu ucinac liste. Kontrola negatywna wbudowana: poprzedni `gen-cron.sh` musi odrzucic kazdy config, ktory sie tu renderuje |
| `subtree` | **10/10** | `validate_subtree` w OBU silnikach — dowod, ze rekurencyjny transfer wyladowal na KAZDYM potomku, nie tylko na korzeniu. Kampania na zywo zmierzyla, ze `zfs recv` strumienia `-R` POMIJA potomka, ktorego stan lokalny nie przyjmuje przyrostu, ladauje reszte i konczy sie zerem — bieg raportowal sukces, a jedno dziecko przestalo byc kopiowane. Pierwsza wersja samej kontroli byla fail-open dwukrotnie (blad inwentarza zwracal „wszystko dobrze"; test przynaleznosci byl PODCIAGIEM, wiec `@s3-extra` spelnial `@s3`) — oba przypadki przypiete tu dyskryminatorami wobec zaslepionych `zfs`/`ssh`. Kontrola negatywna wobec silnikow sprzed poprawki: **4 asercje padaja**, 6 przechodzi |
| `twins` | **26/26** (+2 sekcja D, 2026-08-19) | alarm dryfu ośmiu funkcji, które `snapsend.sh` i `snapget.sh` definiują pod TĄ SAMĄ nazwą i sygnaturą (`get_sorted_snapshots`, `find_conflicting_snapshots`, `find_recursive_name_collisions`, `validate_snapshot`, `find_common_snapshot`, `create_snapshot`, `transfer_data`, `process_dataset`). Przypięty skrót na kopię; zmiana po jednej stronie bez drugiej = FAIL nazywający, która strona się ruszyła. **Nie twierdzi, że bliźniaki są równoważne** — nie są i nie powinny być (`process_dataset` różni się w 450 z ~550 linii, bo push czyta lokalnie i pisze zdalnie, a pull odwrotnie). Zmiany wyłącznie w komentarzach i białych znakach są normalizowane, żeby blessowanie nie stało się odruchem. Cztery tryby awarii zweryfikowane przy budowie: zmiana jednostronna, obustronna, sama zmiana komentarza (cisza), przemianowanie funkcji |
| `statekey` | 16/16 | klucz stanu i jego kolizje |
| `selfupdate` | 28/28 (7 SKIP) | kontroler aktualizacji i rollbacku |
| `zfsbackup` | **538/538** (zmierzone na żywo pve0 2026-08-19: +1 niezmiennik „każdy BatchMode ssh w `zfs-backup.sh` niesie ConnectTimeout + ServerAlive"; wcześniejszy pełny punkt pomiarowy **391/391** 2026-08-11; Faza 4 sekcja 53 +6 commit `9074fe5`; REV-20260810-095 sekcja 54 +5; REV-102 kroki 3/106/107 sekcje 56/56-107 + krok 5 sekcja 57 F3/F4/F5 + F3-residual 8 asercji; REV-108 sekcja 58 +3 pasywne `-e`; REV-110 sekcja 59 +2 exact-prefix; REV-109 L0 `--section retention`) | Faza 4 (sekcja 53, +6, commit `9074fe5`): `add-client --profile=NAME` waliduje profil (`profile_validate_dir`) przed parowaniem, zapisuje wybór w rekordzie klienta; `apply_client_profile_choice()` konsultuje go WYŁĄCZNIE przy pierwszej aktywacji, nigdy przy re-aktywacji — ta sama jednokierunkowa granica co REV-089 dla profilu w ogóle. Testy: nieznana nazwa profilu odmawia przed jakimkolwiek `deploy.sh --pair`; pominięta flaga zapisuje `default` (ścieżka bez wyboru bez zmian); realny drugi profil jest walidowany i zapisywany poprawnie; `apply_client_profile_choice` przetestowane jednostkowo dla wszystkich trzech przypadków (przyjęcie przy pierwszej aktywacji, ignorowanie przy re-aktywacji, no-op na starym rekordzie klienta bez pola `PROFILE`). +5 (REV-20260810-095, sekcja 54): dowód przez REALNY `cmd_activate_client()`, nie tylko helper — z `PROFILE_ACTIVE=default` w env, `PROFILE=alt` z rekordu przebija przez `apply_client_profile_choice` i steruje renderowanym CONFIG-iem (marker: kadencja `send_schedule = 7 * * * *`), a ta kadencja dochodzi do wygenerowanego crona przez prawdziwy `gen-cron.sh`; ścieżka default (pominięty `--profile`) daje semantykę default; reaktywacja dalej ignoruje profil (jednokierunkowa granica REV-089). Kontrola negatywna: neutralizacja `apply_client_profile_choice` w subshellu → zapisany `PROFILE` bezczynny, kandydat wraca do default. Bezpieczne na hostach z crontabem — stub `$SNAPGET` łapie workfile i wychodzi ≠0, więc run umiera na „not installing" PRZED grant-checkiem i instalacją. Nie wykonane: `zfsbackup-live-pair` (prawdziwy `deploy.sh --pair`/`snapget.sh -n`/`gen-cron.sh --install` na dwóch żywych hostach z rootem), zgłoszone jako obowiązek ręczny.

REV-20260810-092 (sekcja 52, +6): recenzent, weryfikując REV-091, znalazł niezależną pozostałość w GATE 2, nie w Fazie 3. `[excluded:]` to sekcja NICZYJA — `gen-cron.sh` skleja wszystkie w jeden `PROTECT_FLAGS` i dokleja go do KAŻDEJ generowanej linii prune w pliku — więc doklejenie brakującego progu przy dodawaniu nowej relacji przepisywało realne polecenie prune relacji już zainstalowanych, czyli łamało dokładnie tę własność, dla której Gate 2 istnieje („dodaj jedną nową niezależną relację → stare bez zmian"). Moja własna asercja z REV-091 nie mogła tego złapać: biegła na fixture zawierającym wyłącznie `[defaults]`, gdzie „instaluje progi" i „mutuje wspólną politykę" są nierozróżnialne, bo nie było czego zaburzyć. Naprawa wg czterech punktów recenzji: `config_has_relationship_policy()` (prawda, gdy istnieje jakakolwiek sekcja `[dataset:]`/`[prune:]`) plus czwarty parametr `global_policy_mode` (domyślnie `auto`, `always` dla `migrate-profile`). Gałęzi „odmów zamiast mutować" świadomie NIE zbudowałem i napisałem dlaczego: `[excluded:]` to jednolita polityka globalna, więc nowa relacja przy brakującym progu jest dokładnie w tym stanie, w którym już są wszystkie istniejące — nie ma konfiguracji, w której nowej nie da się bezpiecznie utworzyć, a stare działają dalej; krok 6 dowodu samej recenzji wymaga zresztą, żeby B powstało w tym stanie. Jedna rzecz ponad wymagane minimum, zgłoszona do odrzucenia: ścieżka odmawiająca naprawy OSTRZEGA, wymieniając brakujące progi — dziedziczenie zainstalowanej polityki jest poprawne, dziedziczenie jej po cichu nie. Asercje celowo na RENDEROWANYM poleceniu `delsnaps.sh`, nie na tekście configu: `PROTECT_FLAGS` powstaje po stronie generatora, więc równość sekcji nie testowałaby tego, co Gate 2 naprawdę obiecuje. Uboczna zmiana zachowania, nazwana wprost: ponowne uruchomienie `setup-server` na zapełnionym CONFIG-u też przestaje odtwarzać progi globalne. REV-20260810-091 (sekcja 51, +7, ZAMKNIĘTY): po REV-090 `ensure_cron_config()` nadal robiła dwie rzeczy bezwarunkowo — doklejała ogólnokonfiguracyjne progi `[excluded:]` i odmawiała na configu pre-GFS — więc `needs_profile=0` nie znaczyło „tylko topologia". Oba pod tę samą bramkę; detekcja pre-GFS zostaje bezwarunkowa (`PROFILE_GFS` czytają dalej kształt prune i podsumowanie), warunkowa jest sama odmowa. Pierwsza wersja bramki F1 była napisana jako `[ ... ] && \` przed pętlą `for` — jako OSTATNIA instrukcja funkcji ustawiałaby jej kod wyjścia na 1 przy zamkniętej bramce, czyli dokładnie ten kształt fail-open, dla którego otwarto REV-084; zamienione na jawny `if` + jawny `return 0`. Kontrola negatywna wobec `e26adc57…`: 343/346, te trzy to dokładnie nowe asercje dyskryminujące; pozostałe cztery (dwa warunki wstępne + dwie asercje, że próg i odmowa NADAL działają tam, gdzie polityka jest generowana) przechodzą po obu stronach z założenia. REV-20260810-090 (sekcja 50, +6, ZAMKNIĘTY): REV-089 zatrzymał regenerację TREŚCI sekcji, ale `cmd_activate_client()` dalej wołał `ensure_cron_config()`, która dalej bezwarunkowo ładowała profil (F1) i dalej doklejała brakujące szablony (F2). Mój dowód przy REV-089 nie mógł tego złapać: sekcja 49 wołała `emit_client_sections()` bezpośrednio i przez cały czas trzymała profil obecny i poprawny — zależność siedziała w wywołującym, którego nie przekroczyłem. LEKCJA: gdy własność brzmi „X nie zależy od Y", test musi USUNĄĆ Y; edytowanie Y i sprawdzanie, że nic się nie zmieniło, to słabsze twierdzenie wyglądające tak samo w zielonej suicie. Naprawa: profil jako zależność LENIWA, `client_section_plan()` jako jedyna implementacja podziału zachowaj/regeneruj (żaden profil nie jest czytany, żeby odpowiedzieć „czy profil jest potrzebny" — to byłoby cykliczne). Kontrola negatywna wobec `c5f04ab0…`: 335/339. REV-20260809-089 (sekcja 49, +11, ZAMKNIĘTY): `emit_client_sections()` przy KAŻDYM wywołaniu usuwał i odtwarzał wszystkie sekcje relacji z AKTUALNEGO profilu — poprawne dokładnie raz, przy CREATE, i cichy kasownik polityki przy każdej późniejszej re-aktywacji. Znalezione przez audyt ścieżki re-aktywacji pod kątem samej własności Fazy 3, spisane jako dyskusja PRZED implementacją (funkcja ma najdłuższą historię recenzji w repo: REV-034 F3, 036, 045, 033 U7/U9/U11, 083) i potwierdzone niezależnie jako REV-089 P1. Naprawa wg wymaganej korekty: pierwsza aktywacja bez zmian (pełna generacja), re-aktywacja bierze zainstalowaną sekcję za bazę i odświeża w miejscu WYŁĄCZNIE `src` i `flags`. Zbiór pól topologicznych wyprowadzony z kontraktów, nie zgadnięty: funkcja pisze od siebie cztery pola, `src`/`flags` zależą od `LOAD_ACCOUNT`/`LOAD_HOST`/`LOAD_FLAGS` (czyli dokładnie tego, co zmienia `set-endpoint`), a `pair_label`/`notify` są czystymi funkcjami nazwy relacji i ścieżki datasetu — nazwy relacji nie da się zmienić (nie ma komendy rename), a dataset o zmienionej ścieżce to inny dataset, który i tak trafia do gałęzi regeneracji; więc nadpisanie ich mogłoby zapisać wyłącznie identyczną wartość, a pozostawienie ich dodatkowo chroni edycję operatora. Sekcje `[prune:]` nie niosą żadnego pola topologicznego, więc własna sekcja prune nie jest ruszana wcale; w trybie sync `[dataset:]` i `[prune:]` leżą pod TĄ SAMĄ ścieżką, więc zachowanie jednej połowy bez drugiej pozwoliłoby prune ominąć sprawdzenie własności — stąd wymóg, żeby OBIE były własne, inaczej para jest regenerowana. Sprawdzenia znacznika własności i fail-closed bez zmian: sekcja, której klient nie jest właścicielem, nadal jest odrzucana, nigdy adoptowana po samym nagłówku. Dodano jedną NOWĄ odmowę: własna sekcja bez pola `src` nie da się odświeżyć, a ciche nic-nie-zrobienie zostawiłoby relację wskazującą stary endpoint z zerowym kodem wyjścia. `migrate-profile` przekazuje `1` jawnie — regeneracja z profilu jest całym sensem tej komendy, a odziedziczenie domyślnego `0` zamieniłoby ją w no-op (lekcja REV-088 F1 zastosowana w drugą stronę). Kontrola negatywna wobec recenzowanej bazy `8d0dc243…`: 328/333, a te 5 to dokładnie nowe asercje dyskryminujące (krok 5, 6, 6b, 7b i odmowa braku `src`). Pisząc krok 6 pierwsza wersja wyrażała dryf profilu WYMYŚLONYM polem — granica profilu je odrzuciła, więc wywołanie umierało i test „przechodziłby" udowadniając wyłącznie, że niepoprawny profil jest odrzucany; poprawione na pola PRAWDZIWE (`recursive` w `dataset.inc`, zmieniony `gfs_pattern` w `prune.inc`). REV-20260809-088 (+1 nad audytem Fazy 2): pierwsza wersja luki nr 6 (poniżej) wsadziła porównanie treści do `ensure_cron_config()`, wywoływanej przy KAŻDEJ (re)aktywacji — zamieniając regułę kolizji w momencie CREATE w stały bramkarz dryfu profilu, łamiąc jawną zasadę jednokierunkowego przekazania (PROFIL -> generuj raz -> CONFIG v4 -> prawda wykonawcza) i uzgodnioną już własność Fazy 3 ("re-aktywacja zachowuje zainstalowaną politykę"). Do tego porównanie było bajtowe, nie semantyczne, wbrew jawnemu brzmieniu Gate 2 ("identyczny szablon SEMANTYCZNIE może być użyty ponownie"). Naprawione (`20f333d9`): `ensure_cron_config()` dostała parametr `check_new_template_collision` (domyślnie 0, sprawdzenie wyłączone), `cmd_activate_client()` przekazuje `1` WYŁĄCZNIE gdy `STATE` przed wywołaniem było `endpoint_verified` (czyli to naprawdę pierwsza aktywacja NOWEJ relacji, nie re-aktywacja już aktywnej). Porównanie znormalizowane przez `profile_emit` (istniejący normalizator tej samej gramatyki pól) i posortowane — różnice w formatowaniu/kolejności pól już nie kolidują. Kontrola negatywna wobec `5f2201c5` (recenzowanej wersji z błędem): 3 z 4 nowych asercji padają z przewidzianych powodów. Przy okazji poprawiono odwołania SHA w `ACTIVE-WORK-PLAN.md`/`DELIVERIES.md` — rebase w międzyczasie zmienił hash commita, a dokumentacja nie została odświeżona (REV-088 F3). REV-20260809-086 (sekcja 48, +4): żywy dowód na metropolis pve1/pve2 pokazał, że pierwotnie planowana druga próba (ta sama nazwa klienta) odmawia na sprawdzeniu unikalności nazwy w `add-client`, PRZED `cmd_seed()` — więc wcale nie dowodziła nowego guarda z REV-085. Poprawiona kampania: druga, RÓŻNIE nazwana relacja, bez własnego `add-client`/parowania, dziedzicząca manifest peera pierwszej (jeden manifest na peera, nie na relację — sam ten fakt był nieoczekiwany), trafia realnie do `cmd_seed()` i zostaje odrzucona przez `assert_no_coverage_overlap()` z nazwaniem konfliktu; CONFIG, crontab i całe poddrzewo ZFS potwierdzone bit-w-bit bez zmian. Przy okazji znaleziony i naprawiony NIEZALEŻNY bug: `read_server_conf()` bezwarunkowo zeruje `CRON_CONFIG` PO wczytaniu rekordu klienta, więc na hoście bez `server.conf` (dokładnie ten przypadek) `remove-client` i re-aktywacja `activate-client` cicho gubiły odczytaną wartość — dla re-aktywacji oznaczałoby to zapis do ŚWIEŻO przeliczonej domyślnej ścieżki configu zamiast do faktycznie zainstalowanej. Naprawione (sekcja 48, kontrola negatywna: 4 nowe asercje padają na starym kodzie). REV-20260809-085 (sekcja 47, +4): `cmd_seed()` wykonywał PRAWDZIWY, nie-suchy odbiór `snapget.sh` bez żadnego sprawdzenia pokrycia — jedyny guard (`assert_no_coverage_overlap`) siedział wewnątrz `emit_client_sections()`, osiąganej dopiero przy `activate-client`, już PO realnym transferze. Przestrzeń nazw trybu backup to `peer_label(PEER_HOST)` (`LOAD_LABEL`), NIE nazwa klienta — więc dwie różnie nazwane relacje do tego samego peera dzielą tę samą przestrzeń `target/label`. Własna wcześniejsza teza implementera w dyskusji live-proof, że nakładanie w trybie backup jest „strukturalnie nieosiągalne", była błędna z dokładnie tego powodu. Naprawa: `cmd_seed()` liczy docelowe ścieżki kandydata zaraz po `load_client_and_connection()` (już po `resolve_mode_datasets`) i wywołuje TEN SAM `assert_no_coverage_overlap()` przed pętlą transferu — bez drugiej implementacji nakładania; guard w `emit_client_sections()` zostaje jako obrona w głębi. Pisanie testu ujawniło kolejny fakt: prawdziwy `MANAGED_PRUNE_SCOPE` klienta GFS to CAŁE poddrzewo `target/label` (rekurencyjnie) — więc dla jednego peera+targetu, gdy istnieje jedna relacja GFS, KAŻDY dataset pod tym samym peerem+targetem już jest objęty; przypadek „rozłączny" w teście musiał użyć INNEGO peera, nie innego datasetu. Kontrola negatywna wobec `f1c4b960`: stary kod wywołuje prawdziwy odbiornik (realny transfer by się wykonał), nowy odmawia z zerem wywołań. Wymagany dowód na żywo (odmowa PRZED jakimkolwiek nowym stanem po stronie odbioru) jeszcze niewykonany — patrz odpowiedź REV-085. REV-20260809-083/084 (sekcje 45/46, +18 nad 292): `coverage_conflicts()`/`assert_no_coverage_overlap()` odmawiają dodania relacji, gdy jej żądana ścieżka jest rodzicem, dzieckiem lub dokładnym trafieniem pokrycia innej AKTYWNEJ relacji — sprawdzane PRZED pierwszą mutacją working configu (sekcja 45, REV-083 F1). Naprawiona wersja: rekord, którego nie da się odczytać/sparsować (albo który parsuje się, ale nie nazywa `CLIENT_NAME`) odmawia, zamiast być cicho pominięty jako „brak konfliktu" — pierwotny `|| exit 0` był fail-open (sekcja 46, REV-084 F1). Sam ten fix ujawnił dwie kolejne wady PRZED pierwszym zielonym przebiegiem: (1) status wyjścia podpowłoki per-rekord, raz skonsumowany przez `|| { ...; return 2; }`, był statusem OSTATNIEGO `path_overlaps && printf` w pętli — dla każdego rekordu, którego OSTATNIA para ścieżek się nie nakłada, to 1 (fałsz), więc każdy zwykły rozłączny rekord raportował się jako „nieczytelny"; naprawa dodaje jawny `exit 0` na końcu podpowłoki, bo konflikty płyną przez wydrukowane linie, nie przez kod wyjścia; (2) `assert_no_coverage_overlap()` odrzucał diagnostykę `coverage_conflicts()` nazywającą zepsuty plik i zawsze umierał z tym samym ogólnym komunikatem — REV-084 wprost wymaga, żeby komunikat nazywał rekord, więc teraz go nazywa. Kontrola negatywna wobec `90bb026` (kopiowanego do korzenia repo, żeby `SCRIPT_DIR` rozwiązał biblioteki): stary kod zwraca rc=0 i brak wyjścia dla nieparsowalnego rekordu, poprawiony rc=2 z nazwaną ścieżką. Wymagany dowód na żywo z REV-083 (nadpisanie pokrycia na prawdziwym hoście, odczyt zwrotny CONFIG/crontaba) NIE wykonany w tej sesji — patrz `docs/internal/reviews/responses/REV-20260809-083.md`, sekcja „required bounded live-host proof". REV-20260804-042/043 (+8 netto): sekcja "clobber" (26) przepisana pod endpoint-normalized identity — jeden job endpoint-switch przechodzi, dwa joby tego samego klienta z jednym porzuconym pod nowym adresem nadal odmawia (kontrprzykład recenzenta), oba zachowane przechodzi, zmiana source datasetu obok endpointu NIE jest maskowana jako endpoint-only, inny klient nadal odmawia. Warstwa orkiestracji `zfs-backup.sh` (+45 tego wieczoru: wykonywalność bloku, listy przecinkowe, uprawnienia i quiesce wyprowadzane z zadań; sekcja 25 przepisana pod `cron_replace_all`, REV-034 F3). Sekcja 35 (+3, REV-036 F5 follow-up): `migrate-to-account` odmawia, gdy którykolwiek crontab jest zapauzowany (`deploy.sh --pause`) — sprawdzane na starcie preflight, przed jakąkolwiek pracą. REV-033 plasterek 6 (+16): sekcja 36 `resolve_mode_datasets` przez zaślepiony `ssh` (fetch scope+hash, weryfikacja T3, zdalny `zfs list -r`, no-op dla klienta z listą i dla klienta bez `--mode`), sekcja 37 walidacja `add-client --mode=`, plus rozszerzenie sekcji 4 (próg `keep=2` dla trzech prefiksów, idempotencja, nie zawęża silniejszego `keep`) i sekcji 5/5b (znacznik własności U11: zgodny znacznik, odmowa bez znacznika i bez wcześniejszego zapisu, zgodność wsteczna przez `MANAGED_DATASETS`, odmowa gdy znacznik nazywa innego klienta). REV-033 plasterek 7 (+2, F4): sekcja 38 — pin tekstu podpowiedzi po `seed` (już nie sugeruje `set-endpoint` jako obowiązkowego), plus `cmd_verify_endpoint` przez zaślepiony wyłącznie `$SNAPGET` (nie `ssh`) z fixture klient+manifest+przypięty klucz — potwierdza, że diagnostyka stderr nieudanego sprawdzenia (np. "CONNECTION-level failure") dociera do operatora zamiast być wyciszana. REV-033 plasterek 8 (+6, F3/U7/U8): sekcja 39 — `snapget_local_base`/`client_local_path` dla obu trybów, `emit_client_sections` (sync) generuje `[dataset:]`/`[prune:]` po gołej ścieżce źródła z `recursive = no` wszędzie, `is_previously_managed` czyta wielowartościowy `MANAGED_PRUNE_SCOPE` jako listę, `add-client --mode=sync` odmawia (U8, przez podstawiony `PVE_NODES_DIR`) / nie odmawia (brak dopasowania węzła) przy enrollmencie. Korekta U9 (+6 netto, po przepisaniu fixture'ów bramki na nowe CLI): `active_endpoint_host_port`/`endpoint_display` dla obu kształtów rekordu, no-op `set-endpoint` na już aktualnym adresie, zapis `ENDPOINT_KNOWN` przy realnym przełączeniu, wciągnięcie uśpionego slotu klienta legacy, awans `verify-endpoint` na znanego kandydata (i odwrotnie — adres, co przestał odpowiadać, sam staje się kandydatem), odmowa z wymienieniem wszystkich wypróbowanych adresów gdy żaden nie odpowiada. Plasterek 9 (+2, U10): `add-client --join-remotely` przekazuje flagę do `deploy.sh --pair` przez podstawiony `$DEPLOY` przechwytujący argv (ten sam wzorzec co `$SNAPGET` w sekcjach 38/39), obecną tylko gdy podana. Plasterek 10 (+3, korekty ról): sekcja 41 — source-grep piny na poprawioną treść trzech komunikatów (`seed`, `final-catchup`, `verify-endpoint`), gdzie "the source" mylnie nazywało peera zaraz obok już poprawnego "this collector". REV-20260804-039 F1: komunikat błędu `add-client` po nieudanym/przerwanym `--pair` mówi teraz wprost, że retry TEJ SAMEJ komendy jest bezpieczny (żywo dowiedzione, patrz nagłówek). Sekcja 23b (+7, REV-20260804-041): `remove-client` na OSTATNIM kliencie — wymuszona awaria podmiany pliku configu PO udanym usunięciu bloku crona (`mv` zaślepiony tylko dla tego jednego wywołania) potwierdza: kod wychodzi niezerowo, `deploy.sh --unpair` nigdy nie jest wywoływany (skrypt-znacznik jako dowód, nie dopasowanie tekstu), rekord klienta i stary config zostają nietknięte, komunikat nazywa dokładny stan mieszany, a retry (prawdziwy `mv`) kończy się czysto z `STATE=removed` |
| `quiescehelper` | **119/119** | granica uprzywilejowana helpera + transakcja grantu + **nadanie dla konta lokalnego (+14)** |
| `join` | **82/82** | walidacja paczki `--join`, granica zaufania; +12 dla `--commit-scope-check` (REV-033 slice 2), +10 dla `--draft-scope-check` (REV-033 plasterek 4), +13 dla `PEER_CONF_MODE`/`--mode` (REV-033 plasterek 5), +5 dla `PEER_CONF_REMOTE_JOIN`/`--join-remotely` (REV-033 plasterek 9, U10) — pole `yes`/nieznana wartość/brak (legacy), `--join-check` je wypisuje, flaga CLI się parsuje. Plasterek 3 (`b7e0478`, revoke-on-narrow) celowo BEZ testu ze stubem `zfs` — ten sam wybór co dla samej pętli grantu w plasterku 2: fałszywy `zfs` dowodziłby wierności własnemu stubowi, nie prawdziwego `zfs allow`/`unallow`/`holds`. `do_pair`'s own scp/ssh/`ssh -t` orchestration (plasterek 9) tym samym wyborem BEZ stubu — patrz addendum "Slice 9". Zweryfikowane na żywo na metropolis pve2, patrz addendum "Slice 3" w odpowiedzi REV-20260802-033 |
| `pause` | **83/0** | `deploy.sh --pause`/`--resume` na okno serwisowe (wymiana dysku, migracja VM). Domyślnie: zakomentowanie TYLKO ciała bloków tego pakietu (markery `lib-cron.sh`, jawny rejestr `PAUSE_KNOWN_BLOCKS`, obcy blok o tej samej gramatyce nietykany — REV-036 F4) w miejscu, wszystko inne w crontabie (roota i konta) chodzi dalej — jednym zapisem przez `cron_replace_all_impl`, nie po bloku (REV-036 F2). `--fullcron` przywraca dawne zachowanie: cały crontab zapisany i zastąpiony jednym placeholderem, stan zapisywany DURABLE przed zamianą crontaba (REV-036 F1) i porównywany bajt-po-bajcie przy resume (REV-036 F3). `--resume` sam rozpoznaje, w którym trybie dany user został zatrzymany; ręczna linia dopisana wewnątrz zapauzowanego bloku w oknie przeżywa resume, nie jest cicho gubiona. `lib-cron.sh` sam odmawia KAŻDEMU zwykłemu pisarzowi (nie tylko `deploy.sh`) nadpisania zapauzowanego kształtu (REV-036 F5) |
| `draftscope` | **35/0** | `deploy.sh --draft-scope` (REV-033 plasterek 4): generuje plik zakresu z prawdziwego inwentarza ZFS peera — domyślnie aktywne datasety jeden poziom pod każdą pulą, poza znanymi systemowymi (`ROOT`, `swap`) i samym korzeniem puli, plus pełny inwentarz jako komentarz. Przeciw stubowanemu `zpool`/`zfs` (ekstrakcja funkcji jak `test/pause`) — właściwy grant/`zfs allow` zostaje bez zmian nietestowany stubem (ta sama zasada co plasterek 2/3). Drugi draft dla tej samej etykiety odmawia zamiast nadpisać; host z samymi systemowymi datasetami odmawia zamiast zapisać pusty plik. +4 (ENROLMENT-AGREED T5): spis rodzin snapshotów jako komentarz obok inwentarza datasetów |
| `joinremote` | **8/8** (dokument podawał 7/7 — zmierzone 2026-08-06, suita jest deterministyczna, `needs = nothing`) | `deploy.sh`'s `remote_scope_stage` (REV-20260804-037 F1, znaleziony przez automatycznego recenzenta w trakcie kampanii live plasterka 10/zadania 26): substage draft/edit/check edytora `--join-remotely` uruchamiany przez `ssh -t`. Stary kod łączył draft i edytor gołym `;` — edytor otwierał się nawet po nieudanym drafcie (mógł stworzyć pusty/częściowy plik zakresu, który generator potem odmawia nadpisać) i `2>/dev/null` gubił jedyną diagnostykę tłumaczącą dlaczego. `$remote_ok` ustawiane od razu po `--join` nigdy nie było rewidowane — nieudany edytor tylko ostrzegał, a końcowe podsumowanie nadal nazywało zakres "zredagowanym". Naprawione: wydzielona funkcja `remote_scope_stage` (ekstrahowalna sed-range jak `do_draft_scope`) zwraca rozróżnialne kody (0=gotowe i zweryfikowane `--commit-scope-check`, 2=draft padł PRZED edytorem, 3=edytor padł, 4=zapis nie przeszedł walidacji po edycji), `do_pair`'s podsumowanie drukuje osobną instrukcję odzysku dla każdego stanu. Przeciw stubowanemu `ssh` (ta sama technika co stubowany `zpool`/`zfs` w `draftscope`): wymuszony brak drafta NIE wywołuje edytora i NIE tworzy pliku (dokładnie wada z F1), istniejący zakres pomija draft, awaria edytora/walidacji nigdy nie twierdzi "gotowe". `do_pair`/`do_join`'s prawdziwe działania (`useradd`, `zfs allow`, transfer po ssh) pozostają bez lokalnego testu z tego samego powodu co zawsze — patrz nagłówek `test/join/run.sh` |
| `pairgate` | **21/21** | `zfs-pair-gate.sh` — brama po stronie peera, stan `DISABLED` z ADR-0012 (pakiet hard-disable, krok 1 z `docs/project/HARD-DISABLE-CAMPAIGN-PLAN.md`). Testowalna bez ssh, bo sshd wnosi dokładnie dwa wejścia: argv (etykieta z `command=`) i `SSH_ORIGINAL_COMMAND`. KAŻDY przypadek data-plane każe bramie uruchomić komendę, której jedynym efektem jest utworzenie pliku, i sprawdza, że pliku NIE MA — „wypisała odmowę" nie jest dowodem, że nic się nie wykonało. Przypięte: odmowa PRZED parsowaniem (wejście nieparsowalne dostaje tę samą odmowę, nie błąd składni); tożsamość z klucza, nie z żądania (żądanie podszywające się pod inną relację niczego nie zmienia); cztery rozróżnialne kody wyjścia 91/92/93 (255 zostaje własnością ssh); nieznana relacja i zła etykieta fail-CLOSED; druga relacja działa dalej; verby kontrolne to dokładne literały, nigdy dopasowanie po prefiksie; `enable` przywraca data-plane, co dowodzone jest realnym efektem ubocznym, nie raportem samej bramy. Druga połowa — czy sshd naprawdę trasuje prawdziwy klucz przez bramę — to obowiązek ręczny `pairgate-live` |
| `pairgate` | **45/45** | brama peera `zfs-pair-gate.sh` + instalacja w `deploy.sh --join` (pakiet hard-disable). Sedno: każdy przypadek data-plane każe bramie uruchomić komendę tworzącą plik i sprawdza, że pliku NIE MA — „wypisała odmowę" nie jest dowodem. Przypięte: odmowa przed parsowaniem, tożsamość z klucza a nie z żądania, kody 91/92/93 rozróżnialne, fail-closed przy nieznanej relacji i złej etykiecie, verby kontrolne jako dokładne literały, logowanie do syslogu z zejściem do pliku wybieranym po WYNIKU a nie po obecności `logger` (REV-047 F1) i nigdy nie zanieczyszczające stderr wywołującego. Instalacja: migracja gołej linii klucza bez pozostawienia jej obok bramkowanej, cudze linie bajt w bajt, idempotencja, awaria commitu bez tknięcia pliku, i fail-closed na własności pliku — bo podmiana atomowa rootem odbiera kontu dostęp do własnego hosta (REV-049 F1) |
| `moveclient` | **41/0** | `move-to-client`: relacja, ktorej maszyna zostala WYMIENIONA, oddaje kopie nowej — kopia nie rusza sie z dysku, zmienia sie tylko to, z ktorej maszyny jest backupowana, wiec nie ma ponownego seedu. Suita pokrywa trzy czyste przeksztalcenia (flagi, znacznik `managed-by`, naglowek sekcji) DOKLADNIE, a dowod po GUID przez stuby — czyli jego LOGIKE: brak snapshotu odmawia, niezgodny GUID odmawia, zgodny przechodzi, a nieczytelna odpowiedz NIGDY nie jest przepustka. To, ze ZFS zachowuje GUID przez send/recv, jest wlasnoscia ZFS i nalezy do labu. Podmiana flag zamienia cztery rzeczy (klucz, known_hosts, alias, etykieta) i zostawia reszte bajt w bajt — przepisanie calego pola skasowaloby po cichu limit pasma. Przepiecie znacznika ma kontrole ujemna: gdy znacznika nie ma, zwraca 3, a nie cichy no-op |
| `mediagate` | **109/0** | klamra `import`/`export` wokol repliki na nosnik WYMIENNY. Asercja, dla ktorej ta suita istnieje, to ta o NIE-eksportowaniu: pula, ktorej ten przebieg nie zaimportowal, nalezy do tego, kto to zrobil, i wyeksportowanie jej wyrwaloby mu grunt spod nog — sprawdzone w obie strony, bo straznik widzacy tylko przypadek bezpieczny nie jest straznikiem. Dalej: brak nosnika to `exit 1` i slowo SKIPPED, nie awaria; pula zaimportowana BEZ oczekiwanego datasetu to `exit 2` — zly dysk w kieszeni, nie brak dysku; dwie pule tej samej nazwy to dwa dyski naraz i odmowa zamiast wyboru (rotowane nosniki zwykle maja te sama nazwe); nieudany eksport krzyczy DO NOT UNPLUG. `zpool`/`zfs` sa stubowane, wiec sprawdzana jest DECYZJA, nie ZFS. Sekcja G idzie dalej i uruchamia CALA wygenerowana linie crona z prawdziwego `gen-cron.sh`, stubujac tylko bramke i silnik — bo dwie wady przeszly obok suity, ktora badala sama bramke: klamra wstawiona jako ciag polecen w miejsce na JEDNO powodowala, ze `2>"$e"` i `rc=$?` wiazaly sie tylko z `detach` (silnik konczyl 1, zadanie zapisywalo rc=0 i nikt nie dostawal maila), a bramce podawano sciezke DOCELOWA, ktora tworzy silnik, wiec swiezo przygotowany dysk byl przy pierwszym biegu odrzucany jako „zly nosnik". Obie maja kontrole ujemna. Sekcja H pilnuje KOTWICY: `[prune-bookmarks:]` obejmujacy zrodlo repliki wymiennej jest zglaszany (z konsekwencja: nastepny bieg po powrocie dysku bedzie PELNYM przesiewem), ale nie odmawiany i nie wykluczany po cichu — rotacja dyskow to fakt admina, nie generatora. Strona negatywna jest rowna wazna i sprawdzana: zwykly cel, wzorzec nie mogacy trafic w `tgt-`, oraz zakres rodzica bez `recursive` NIE sa zglaszane. **Sekcja I (REV-124 F1)** to jedyny test CYKLU ZYCIA, a nie pojedynczego biegu: nasz `attach` przechodzi, bieg ginie przed `detach`, kolejny zastaje pule zaimportowana. Znacznik wlasnosci musi PRZEZYC ten retry — wczesniej byl kasowany, bo „pula juz zaimportowana" czytano jako „czyjas decyzja", co jest prawda dokladnie raz: gdy sami jej nie importowalismy. Skutkiem bylo, ze `detach` zglaszal sukces bez eksportu, i tak samo kazda nastepna proba: dysk zostawal zywy w nieskonczonosc, a zadanie mowilo, ze mozna go wyjac. Znacznik niesie teraz GUID puli; niezgodny GUID (rotowane nosniki dziela nazwe) to odmowa, nie zgadywanie |
| `restoregrant` | **44/44** (+1 SKIP) | zgoda na odtwarzanie: fakt na maszynie ZAGROZONEJ, ktory pozwala kolektorowi ja nadpisac. Sedno suity to sekcja 1 — MIEJSCE. Projekt klad zgode w `relationships/<label>/` i w tym samym akapicie twierdzil, ze katalog jest „root-owned, read-only for the account"; `deploy.sh` robi go `root:<konto>` **0775**, bo klucz relacji musi moc zdjac twarda pauze (unlink znacznika W TYM katalogu). Zgoda trzymana tam moglaby wiec zostac zalozona przez konto, przed ktorym chroni. Asercja strukturalna: drzewo zgod NIE moze lezec pod drzewem relacji, bramka czyta to samo drzewo, plus kontrola negatywna, ze tamten katalog NAPRAWDE jest grupowo-zapisywalny — inaczej regula bronilaby wymyslonego zagrozenia. Dalej: root wymagany do nadania i odebrania, `--show-restore` czytelny bez roota; nieznana relacja i zla etykieta odmawiaja i nic nie zapisuja (w tym `../etc` — nic poza drzewem); `replace` nigdy domyslne, poszerzenie zywej zgody ODMAWIA nazywajac obie wartosci, te same tryby to no-op sukces; brak `expires` i `nonce` sprawdzany gerpem; bramka raportuje zgode w obu stanach relacji i FAIL-CLOSED na kazdej wartosci, ktorej nie umie sparsowac (cztery smieci + kontrola pozytywna); bramka NIGDY nie tworzy zgody — trzy proby czasownikiem plus asercja strukturalna zakazujaca jakiegokolwiek zapisu do tego drzewa. Defekt znaleziony przez te suite: `--allow-restore=` z pusta wartoscia przelatywalo przez `[ -n ... ]` i deploy szedl do Fazy 1 — czasownik o UPRAWNIENIACH zaczynal instalowac pakiety (klasa F4); naprawione dyskryminatorem `*_GIVEN`. SKIP: `chmod 000` nie odbiera prawa wlascicielowi na Git Bash/NTFS, wiec asercja o nieczytelnym pliku zglasza pominiecie zamiast udawac, ze cos zmierzyla |
| `pairpause` | **18/18** | pauza logiczna relacji (REV-20260804-045): bramka `-L` w snapget.sh/snapsend.sh uruchamiana na PRAWDZIWYCH skryptach end-to-end (pozycja bramki jest testowaną własnością — pauza wychodzi z SKIPPED+`skipped_paused` PRZED zamkiem i sprawdzeniami zależności, co czyni ją dowodliwą bez roota/ZFS); etykieta niezapauzowana i brak etykiety płyną dalej (to drugie to UDOKUMENTOWANE ograniczenie, przypięte jako zachowanie); traversal odrzucony zanim jakakolwiek ścieżka jest dotknięta; `-L ''` = brak etykiety. Plus `check-snap-age -L`: pauza = OK z nazwanym powodem (nie cisza, nie strona), zepsuty próg pozostaje głośnym UNKNOWN także podczas pauzy. CLI zapisujące marker: `test/zfsbackup` sekcja 42; emisja `pair_label`: golden `pair-label` + negatyw `pair-label-charset` w suicie gencron |
| `runsuffix` | **6/6** | jeden sufiks nazwy snapshotu na PRZEBIEG, nie na dataset (Etap 2.1). Własność, od której zależy restore: zestawu snapshotów, którego nie da się zidentyfikować jako jednego przebiegu, nie da się odtworzyć jako jednego. `create_snapshot` wyekstrahowane z OBU silników, `date(1)` zaślepione tak, by zwracało INNĄ wartość przy każdym wywołaniu — dokładnie to, co robi prawdziwe poddrzewo przekraczające granicę sekundy. Przypina też KSZTAŁT nazwy, bo zależą od niego wzorce `delsnaps`, prefiksy monitora i każda zainstalowana linia crona. Licznik zaślepki żyje w PLIKU, nie w zmiennej: `$(date ...)` biegnie w podpowłoce, więc licznik na zmiennej zwracałby tę samą wartość i kontrola negatywna przeszłaby na STARYM kodzie, nie dowodząc niczego (pierwsza wersja tego testu robiła dokładnie to). Kontrola negatywna wobec `643238a`: **2 przypadki korelacji padają, 4 nietknięte przechodzą**. Korelacja end-to-end na prawdziwym ZFS-ie należy do `test/scenarios`; ta suita przypina samą decyzję o nazywaniu |

**Zintegrowana kampania po Etapie 2 — WYKONANA** (2026-08-08, metropolis pve1, kandydat `4b30447`). Pełny wynik: `docs/testing/POST-STAGE2-CAMPAIGN-RESULTS-2026-08-08.md`. **619 asercji, 0 porażek**, w tym `snapsend` 202/202, `remote` 145/145 jako konto delegowane (co domyka obowiązek ręczny `nonroot-account`), `delsnaps` 65/65, `scenarios` 36/36. Kampania znalazła jedną realną wadę — `test/pairpause` fałszywie padała na KAŻDYM hoście (asercja opierała się na kodzie wyjścia, który zależy od obecności ZFS-a); zdiagnozowane jako niezwiązane z Etapem 2 przez przebieg tej samej suity na `643238a` (identyczne 12/6) i naprawione. To był pierwszy raz, gdy ta suita w ogóle biegła na hoście.

**Dowód na żywo dla Etapu 2.1 (2026-08-08, metropolis pve1, `42fd7de`).** Kontrakt wymagał JEDNEGO scenariusza na prawdziwym ZFS-ie dowodzącego korelacji end to end — suita `scenarios` tego NIE pokrywa (sprawdzone: zero trafień na sufiks/korelację), więc dług był realny.

Drzewo robocze `hdd/rs-src` + trzy dzieci po 300 MB losowych danych, żeby przebieg trwał sekundy i naprawdę przekroczył granicę sekundy. Wywołanie długą pisownią, więc ten sam przebieg dowodzi też 2.3 na prawdziwym transferze:

```
./snapsend.sh --recursive=flat -m runcorr_ hdd/rs-src hdd/rs-dst     # 04:23:04 -> 04:23:30, rc=0
hdd/rs-src@runcorr_2026-08-08_04-23-04
hdd/rs-src/a@runcorr_2026-08-08_04-23-04
hdd/rs-src/b@runcorr_2026-08-08_04-23-04
hdd/rs-src/c@runcorr_2026-08-08_04-23-04
```

26 sekund przebiegu, **jeden sufiks na wszystkich czterech datasetach**.

Kontrola negatywna na TYM SAMYM drzewie, silnikiem z `643238a` (sprzed 2.1), przez `git worktree`:

```
./snapsend.sh -R -m oldcorr_ hdd/rs-src hdd/rs-dst2                  # 04:23:50 -> 04:24:18, rc=0
hdd/rs-src@oldcorr_2026-08-08_04-23-50
hdd/rs-src/a@oldcorr_2026-08-08_04-23-54
hdd/rs-src/b@oldcorr_2026-08-08_04-24-03
hdd/rs-src/c@oldcorr_2026-08-08_04-24-11
```

**Cztery różne sufiksy rozrzucone na 21 sekund** — dokładnie ta niekorelowalność, dla której powstał Etap 2.1, zaobserwowana, a nie wywnioskowana. Wszystkie datasety robocze zniszczone po teście, worktree usunięty.
| `reconcile` | **47/47** | `gen-cron.sh --reconcile` (uzgadnianie zakresu): co config kopiuje kontra co naprawdę istnieje. Odpowiada na awarię z tej floty, nie z wyobraźni — VM 104 na pve0 działała z ZEREM snapshotów, bo powstała po napisaniu configu, a nic tych dwóch faktów nie porównywało. `zfs`/`qm`/`pct` zaślepione, więc testowane jest PORÓWNANIE, nie zfs. Przypina, że „pokryty" znaczy **istnieje zadanie wysyłki** (dataset z samym prune jest przycinany, nie kopiowany); że audyt czyta ZADEKLAROWANE pole `recursive`, a nie zakłada, że rodzic pokrywa poddrzewo; że zadanie o nieistniejącym źródle jest zgłaszane; oraz że datasety systemowe Proxmoksa są WYPISANE I OZNACZONE, a nie po cichu wycięte — celowo odwrotny kierunek niż `deploy.sh --draft-scope`, bo tam wąski domyślny wybór jest bezpieczny, a tu przemilczenie JEST tą wadą. Przypisanie do gościa to ETYKIETA, nigdy decyzja. Zweryfikowane MUTACJĄ, nie tym, że stary kod nie zna flagi: zignorowanie pola `recursive` wywala 2 przypadki, ciche pomijanie datasetów systemowych — 1. Tryb jest READ-ONLY: nie zmienia configu, nie pisze crontaba, nie dotyka snapshotów. +11 (REV-20260808-071 F1/F2): drzewa ODEBRANE sa klasyfikowane osobno, a nie jako „nieobjete”. Audyt porownywal wylacznie z zadaniami WYSYLKI i nigdy nie pytal, co zadanie ZAPISUJE — wiec drzewo odebrane przez kolektor bylo zglaszane jako brak kopii, czyli zadanie, zeby kopia zapasowa miala kopie zapasowa; na pve2 to byla wiekszosc wyniku, a etykieta goscia czynila to jeszcze bardziej mylacym. Wyprowadzane z TOPOLOGII configu, nigdy z nazw: push z lokalnym dst -> `<dst>/<sciezka zrodla>`, push zdalny -> cel jest na peerze i NIE da sie go tu wyprowadzic (ograniczenie zgloszone, nie zgadywane), pull -> `<sekcja>/<nazwa zdalna>`. Poziomy posrednie tworzone przez odbior dopasowywane DOKLADNIE, nie poddrzewem — inaczej cokolwiek podlozone pod cel byloby po cichu rozgrzeszone. F2: kotwica systemowa obejmuje POTOMKOW (`rpool/ROOT/pve-1` to zwykly dataset rozruchowy Proxmoksa, byl zglaszany jako nieobjety), a granica, ktora dzialala, zostaje: `rpool/data/swap` nie jest POD kotwica, wiec pozostaje zwyklym znaleziskiem. Kontrole mutacyjne: odkotwiczenie dopasowania systemowego wywala granice z zagniezdzonym `swap`. +3 (REV-20260808-071, dyrektywa 3 i 4): pokrycie wyprowadzane z RZECZYWISCIE zbudowanych bytow wysylkowych i tylko z kierunku PUSH — sekcja bez rozwiazanego harmonogramu wysylki (sam prune) NIE jest pokryta, a cel PULL-a to miejsce, gdzie kopia LADUJE, wiec nie jest pokryciem zrodlowym. Poprawna sekcja pull ma sciezke konczaca sie literalna nazwa zdalnego datasetu (wymusza to `emit_send`), wiec korzeniem odbioru jest sama sekcja; poprzedni test uzywal configu, ktory normalne generowanie ODRZUCA, i przechodzil tylko dlatego, ze `--reconcile` konczy przed walidacja sufiksu. Kontrola wobec `8b578bd`: **4 nowe asercje padaja**, 25 istniejacych przechodzi. +3 (REV-20260808-072 F1): PARYTET ODMOWY — kontrakt pull-a (lokalna sciezka musi konczyc sie literalna nazwa zdalnego datasetu) zyl wylacznie w `emit_send`, do ktorego `--reconcile` nigdy nie dochodzi. Audyt mogl wiec wystawic czyste swiadectwo configowi, ktorego generator odmawia wykonac — sprawdzacz bardziej pobalzliwy niz rzecz sprawdzana jest gorszy niz brak sprawdzacza. Regula wydzielona do `pull_check` i wolana z `validate_transfer_semantics` PRZED galezia reconcile, wiec audyt i generator przyjmuja dokladnie te same wejscia. `pull_check` zwraca STATUS i ustawia globalne, nie echuje — gdyby echowala, `die` w podstawieniu polecen zabilby tylko podpowloke, czyli fail-OPEN juz raz w tym projekcie odnotowany. Kontrola wobec `96fbfbf`: padaja dokladnie 2 asercje parytetu, a „normalne generowanie odrzuca” przechodzi tam tez, bo zawsze dzialalo. +9 (decyzja wlasciciela 2026-08-08): KONTENERY STRUKTURALNE tlumione — rodzic, ktorego wszystkie dzieci sa pokryte i ktory nie trzyma wlasnych danych, to przypadek udokumentowany przez flage `-S` snapsenda. Dwie straze: JEDNO niepokryte dziecko i rodzic zostaje znaleziskiem; `usedbydataset` powyzej 1 MiB znaczy, ze ktos wlozyl pliki wprost do rodzica i te dane nie maja kopii. Tlumione = nieliczone i niealarmujace, NIGDY niewidoczne (wlasny naglowek, jak datasety systemowe). Plus poprawka FALSZYWEGO NEGATYWU: ekspansja rekursji honoruje teraz `-S` i `-X` — `zfs list -r` przypisywal pokrycie rodzicowi, ktorego silnik pomija, i dziecku, ktore odfiltrowuje. Utajone, nie czynne: zaden config w tej flocie tych flag nie uzywa. Kontrola wobec `5c5ee1e`: **5 asercji pada**, 36 przechodzi. +6 (REV-20260808-074 follow-up): KLASTROWANE pisownie `-S`/`-X`. Silnik uzywa `getopts`, wiec `-eS` to `-e` plus `-S`, a `-SX drop$` to `-S` plus `-X` biorace nastepny token. `--reconcile` mial WLASNY chodzik po tokenach, rozpoznajacy tylko `-S`, `-X` i `-Xwzor` jako cale tokeny, wiec te legalne pisownie byly zle czytane, a pominiety rodzic albo wykluczone dziecko wracalo jako POKRYTE — falszywa zielen. Ta sama wada, ktora REV-069 naprawila w pre-passie silnikow, napisana recznie drugi raz w innym pliku. Poprawka to JEDNA gramatyka: `flags_opt_pairs` robi przejscie rownowazne `getopts` i zwraca litere z argumentem, a `flags_opt_letters` jest widokiem tego samego przejscia. Kontrola wobec `5914498`: **3 asercje padaja**; pozostale 3 przechodza tam tez (stary parser poprawnie czytal `-X fooS`) i sa pokryciem regresyjnym, nie dowodem |
| `recursion` | **64/64** | dokładnie JEDNA deklaracja rekursji na wywołanie + długie opcje (Etapy 2.2 i 2.3). Na PRAWDZIWYCH silnikach: odmowa zapada przy parsowaniu argv, przed sprawdzeniem zależności, datasetu i SSH — dlatego bez roota i ZFS-a. Przypięte: `-r -R` odrzucane w OBU kolejnościach (było prawdą już wcześniej, kontrakt twierdził inaczej); powtórzenie TEGO SAMEGO trybu też odrzucane; litera rekursji jako ARGUMENT OPCJI (`-m -r`) to dana. **2.3:** `--recursive=atomic|flat|no` równoważne `-r`/`-R`/braku, `--recursive=ture` odrzucane z podaniem wartości, gołe `--recursive` odrzucane, nieznana długa opcja odrzucana; `--recursive=no -r` **odrzucane, nie zwijane do `-r`** (przypadek, który REV-060 A4 wyłapała w mojej pierwszej propozycji); mieszanie form krótkiej i długiej to dwie deklaracje; po `--` i po pierwszym pozycyjnym długie formy są danymi (obie reguły stopu `getopts`). `delsnaps`/`check-snap-age` dostają `--recursive` ≡ `-R` — testowane przez EKSTRAKCJĘ pętli argumentów, bo oba giną na braku `flock`/`zfs` ZANIM do niej dojdą, więc samo uruchomienie „przyjmuje" literówkę równie chętnie co poprawną pisownię. Kontrola negatywna wobec `bda5602`: **20 asercji pada**, 34 przechodzą. +10 (REV-20260808-069 F1): KLASTRY flag krótkich. `getopts` czyta `-em` jako `-e` i `-m`, a skoro `m:` bierze argument i nic po nim w tokenie nie zostaje, argumentem jest NASTĘPNY argv. Pierwszy pre-pass pochłaniał następny argv tylko dla tokenu długości 2, więc `-em --recursive=flat` czytał WIADOMOŚĆ jako deklarację. Sondą jest celowo NIEPOPRAWNY tryb (`ture`) — „brak błędu" niczego tu nie dowodzi, bo poprawny tryb milczy w obu interpretacjach, a druga deklaracja bywa połknięta jako argument opcji; obie moje pierwsze sondy były z tego powodu ślepe. Kontrola wobec `46b96b4`: **2 asercje padają** (`-em` w obu silnikach), reszta przechodzi — pozostałe przypadki klastrowe stary kod obsługiwał przypadkiem poprawnie |

**Dowód na żywo dla Etapu 2.3 (2026-08-08, `3d44488`).** Kontrakt wymagał JEDNEGO wywołania jako konto delegowane, dowodzącego, że **zainstalowana** kopia rozumie nową pisownię — wykonane na **wszystkich czterech hostach** (metropolis pve1/pve2, 11.x pve0/pve1), jako `zfsbackup`, na nieistniejącej puli, więc obie sondy kończą się na parsowaniu argumentów i niczego nie dotykają:

- sonda A `--recursive=ture` → `Error: --recursive= takes atomic, flat or no (got 'ture')`, rc=1 na każdym hoście — dowodzi, że wdrożona kopia PARSUJE długą opcję;
- sonda B `-em --recursive=ture` → **zero** walidacji wartości na każdym hoście — dowodzi, że poprawka REV-20260808-069 (klastry) jest wdrożona, a nie tylko zacommitowana;
- `--recursive=no -r` odrzucone jako dwie deklaracje, `snapget.sh` zachowuje się identycznie.

Sonda z NIEPOPRAWNYM trybem jest tu jedyną obserwacją rozróżniającą: poprawny tryb milczy niezależnie od tego, czy token jest daną, czy opcją. `git log` jako root na hostach 11.x odmawia przez `safe.directory` (repo należy do `zfsbackup`) — to kontrola własności po stronie roota, nie problem wdrożenia; commit odczytany jako konto delegowane.
| `alertmail` | **18/18** | audyt dostarczalności alertów `deploy.sh` (REV-20260806-046): kwartet `mta_present`/`mta_name`/`mail_queue_depth`/`alert_delivery_verdict` + aktywna sonda `alert_delivery_probe` na podstawionych `mail`/`postqueue`/`sleep`, z wyjętym z deploy.sh oryginalnym `warn()`. Klasa findingu: FAŁSZYWE ZDROWIE — werdykt nieoparty na zmierzonych dowodach. Przypięte: brak `mail(1)`/MTA i niepusta kolejka pozostają twardymi awariami zasilającymi `PROBLEMS`; kolejka nieczytelna (MTA bez obsługiwanego narzędzia, `postqueue` sam padł, wyjście nienumeryczne) jest UNVERIFIED i niezielona zamiast dawnego `log()`+`return 0`; pusta kolejka bez sondy mówi „prerequisites OK, delivery UNVERIFIED", nigdy „can send" (grep w obie strony — brak pozytywu, obecność UNVERIFIED); sonda sprawdza status `mail(1)` i po opróżnieniu kolejki twierdzi wyłącznie „LEFT THIS MTA, recipient delivery NOT independently verified". Każdy przypadek sprawdza jednocześnie kod powrotu, licznik `PROBLEMS` i brzmienie. Przypadki regresyjne F1/F2 padają na zrecenzowanej bazie `a567328` (`DEPLOY_SRC=`). Prawdziwy postfix i faktyczne dostarczenie: dowód żywy w odpowiedzi REV-046 + obowiązek ręczny `deploy-check-only` |
| `joinmanifest` | **27/0** | `deploy.sh`'s `verify_join_manifest` (REV-20260804-038, znaleziony przez automatycznego recenzenta na podstawie tego samego incydentu live co plasterek — brakujący `PEER_CONF_MODE` zostawił PUSTY manifest na dysku, a `do_join()` mimo to wypisał "Join zakonczony"). Stary kod pisał manifest bezpośrednio (`cat > "$mpath"; chmod`), bez sprawdzenia i bez atomowości, PO mutacjach konta/klucza. Naprawione: render do pliku tymczasowego w tym samym katalogu, weryfikacja odczytu wszystkich pól PRZED zaufaniem, atomowy `mv`, ponowna weryfikacja PO rename — każda awaria zwraca niezerowo z jawną diagnostyką "PARTIAL ENROLMENT" (konto/klucz mogą już istnieć, bezpiecznie powtórzyć `--join` tym samym pakietem, nigdy nie kasować konta/klucza ręcznie). Przeciw prawdziwym plikom (bez ssh/zfs/useradd): poprawny manifest weryfikuje się dokładnie; kształt incydentu live (plik pusty) jest odrzucany; pojedyncze złe pole (fingerprint, konto) jest odrzucane, co dowodzi porównania KAŻDEGO pola; brakujący plik odrzucony; manifest legacy bez `PEER_JOIN_REMOTE` weryfikuje się poprawnie, gdy nie był oczekiwany. +3 (REV-20260804-040): pole `PEER_JOIN_ACCOUNT_UID` — manifest z zapisanym UID weryfikuje się dokładnie przy zgodności, odmawia przy niezgodności, manifest legacy bez tego pola nadal weryfikuje się gdy UID nie był oczekiwany. Sama sekwencja render/write/chmod/rename w `do_join()` nadal wymaga roota (podobnie jak mutacje konta/klucza przed nią) — ten sam stały brak co zawsze | **Zbuforowany szkic zakresu (2026-08-29)**: szkic jest ponownie uzywany przy kolejnym `--join`, i slusznie — to dokument zgody, ktory admin mogl recznie edytowac, a ciche przebudowanie skasowaloby te edycje. Ale prosba kolektora moze sie miedzy probami ZMIENIC, i wtedy ekran akceptacji pokazywal biezaca prosbe tuz nad liczba i nadaniem policzonymi ze STAREGO szkicu. Zmierzone na pve9 przy budowie labu move-to-client: pierwszy join bez `--datasets` narysowal caly majatek, `add-client` powtorzono z `--datasets=hdd/movelab/src`, a nastepny join wypisal „Kolektor prosil o: hdd/movelab/src" i cztery linie nizej „Przyjecie nada ... na 9 dataset(ach)". Prosba o jeden dataset i nadanie na dziewieciu, jednoczesnie na ekranie. Szkic niesie teraz metryczke z prosba, ktora go zrodzila; DOWIEDZIONA rozbieznosc odmawia, brak metryczki (kazdy host w trakcie joinu w chwili aktualizacji) jest glosno mowiony, nie zamieniany w odmowe na dowodzie, ktorego nikt nie ma.

Wymagają roota, ZFS albo drugiego hosta. **Uruchomione 2026-08-04 na metropolis
pve1 przy `4ebfa11`** (i wcześniej przy `d8bb52a`, `244ec0d`, `55d33a2`) — pierwszy
przebieg od czasu, gdy REV-20260802-033 plasterek 8 dotknął `snapget.sh`
(root+zfs nie było dostępne w sesji implementującej ten plasterek). Znalazł
na żywo dwa realne błędy istniejące od plasterka 8, oba naprawione w tej
samej kampanii co REV-20260804-037/038 (patrz tam pełny rejestr Gate A-J):
`recv_force_flag` odmawiał KAŻDEGO pierwszego seeda (cel zawsze jest
wstępnie tworzony pusty, co czyniło `target_exists()` prawdziwym zawsze),
i `written@` porównywało sformatowaną wartość (`"0B"`) z gołą cyfrą
(`"0"`), więc odmawiało też przy zerowej rozbieżności — w tym w przypadku
dopasowania po GUID, gdzie migawka na celu ma inną nazwę niż na źródle
(`written@<nazwa-źródła>` na celu zwracał `"-"`, nie liczbę):

| Pakiet | Wynik | Czego wymaga | Zakres |
|---|---|---|---|
| `snapsend` | **202/202** | root, zfs, mbuffer | silnik push/pull, semantyka flag |
| `scenarios` | **34/34** | root, zfs, mbuffer | wygenerowane linie crona uruchamiane dosłownie |
| `remote` | **145/145** | drugi host, ssh, zfs | kampania dwuhostowa, **oba klastry, root i konto**: metropolis pve1 → pve2; 192.168.11.x pve0 → pve1 (root `--peer-parent rpool`, konto `rpool/data` po obu stronach) |
| `delsnaps` | — | root, zfs | retencja, prefiksy, GFS — poza grafem dla tej zmiany |

Siedem pozycji `SKIP` w `selfupdate` to przypadki wymagające `chattr +i`, którego
to środowisko nie obsługuje.

Wszystkie pakiety wymienione w `test/deps.conf` muszą występować w tej tabeli;
pilnuje tego `test/impact/run.sh`.

Zweryfikowane na żywo 2026-07-31: `sqlfreeze` na produkcyjnym vsql2 (VM 100),
reguła kropki w `sudoers.d` (visudo 1.9.5p2, z kontrolą negatywną), akceptacja
generowanej reguły sudoers przez prawdziwy `visudo`, `deploy.sh --check-only` na
czterech hostach w obu formach hosta.

## 6. Otwarte — i u kogo leży

### LEDGER PUSTY — zero recenzji w toku (2026-08-31, `main` @ `bd6797f`)

`docs/internal/reviews/REVIEW_LEDGER.md` nie ma **ani jednego** wiersza poza
`CLOSED`: wszystkie **65** recenzji zamknięte, zero `OPEN | Claude`, zero
`IMPLEMENTED | Reviewer`, zero otwartych Pull Requestów. Ostatnie dwie —
REV-20260831-128 (proweniencja wyboru dla `--onto`) i REV-20260831-129
(tożsamość per dataset w sprawdzeniu rekurencyjnym) — recenzent zatwierdził i
zamknął tego dnia, PR #231 i #232.

**Autorytetem jest wygenerowany ledger na świeżo opublikowanym `main`, nie ten
akapit.** Jeśli oba się rozjadą, rację ma ledger, a to zdanie jest po prostu
przeterminowane — dlatego nazywa commit, na którym zostało zmierzone. Ten
dokument opisuje stan produktu i nigdy nie rozstrzyga, czyj jest ruch.

Podsekcje niżej to **zapis historyczny** — kto na co czekał w sierpniu. Żadna z
opisanych tam recenzji nie jest już otwarta; zostają, bo tłumaczą, skąd wzięły
się dzisiejsze mechanizmy. Jedyne, co przeżyło jako **bieżące**, to nazwane
luki produktowe pod „Znane luki" — i one nie są stanem recenzji.

### Zamknięte przez recenzenta

- **REV-20260731-013 — odzyskiwanie po crashu: ZAMKNIĘTE** (REV-014). Sweep
  parkuje zaparkowaną regułę zamiast ją uzbrajać; recenzent uznał zachowanie za
  poprawnie fail-closed i przyjął, że testy mierzą efektywną granicę, a nie
  obecność plików.
- **Poprawka `sqlfreeze` (warunkowa notka): PRZYJĘTA** tą samą recenzją.
- **REV-20260731-012 — kolejność commitu: przyjęta** w REV-013.
- **Transakcja grantu wraz z odzyskiwaniem po crashu** jest przez recenzenta
  uznana za akceptowalną infrastrukturę dla **opcjonalnego** remote quiesce.

### Historia: co leżało u implementera (sierpień 2026 — wszystko zamknięte)

- **REV-057 — ZAMKNIĘTE.** Migracja wykonana i zweryfikowana; odpowiedź:
  `docs/internal/reviews/responses/REV-20260807-057.md`. REV-054, REV-055,
  REV-056 i REV-058 zamknięte tak samo.
- **Znane luki produktowe — to NIE jest stan recenzji.** Nazwane w odpowiedziach
  z początku sierpnia i od tego czasu **nie weryfikowane ponownie**; (1) i (3)
  sprawdzone pobieżnie 2026-08-31 i nadal wyglądają na otwarte, (2) i (4) nie
  sprawdzone. Traktować jako listę do potwierdzenia, nie jako pomiar: (1) `cron2conf.sh`
  **nie parsuje w ogóle linii `snapget.sh`**, więc połowa round-tripu dla pull
  jest nietestowalna — usterka sprzed tych zmian, znaleziona przy budowie
  fixture'a (wątek #21d); (2) `--draft-config` nie ma testu behawioralnego, bo
  wymaga prawdziwego parowania — D1/D2 w `draftscope` to **statyczny odczyt
  `deploy.sh`**, nie uruchomienie CLI; (3) silniki transferu **nie odrzucają
  `-r -R` naraz** — wygrywa ostatnia flaga, choć generator odmawia tego w
  configu (wątek #31); (4) pod `flat` bez `-q` nazwa snapshotu jest liczona
  osobno dla każdego datasetu, więc przebieg nie jest korelowalny — jednolinijkowa
  zmiana należąca do prac przed zamrożeniem silnika (wątek #30).

### Otwarte u właściciela — decyzje, nie kod

- ~~Migracja 192.168.11.11~~ — **WYKONANA 2026-08-07 14:42** przez
  `gen-cron.sh --migrate-recursion` (REV-057). Crontab md5 **bez zmian**,
  właściciel i prawa zachowane, kopia rollback zostawiona, render identyczny z
  zainstalowanym blokiem. **Żaden config we flocie nie niesie już starego
  zapisu rekurencji** — pakiet rekurencji jest operacyjnie kompletny.
- ~~pve0: goście bez żadnej kopii~~ — **ZAŁATWIONE 2026-08-07 (Etap 0).** VM 104
  `debian` (działająca), VM 103, VM 107 (trzy datasety) i CT 105 są objęte kopią,
  granty nadane, monitor `rc=0`. Zostaje decyzja **strukturalna, nie awaryjna**:
  granty na pve0 są per dataset, więc nowy gość znów wymaga ręcznego kroku.
  Nadanie grantu na rodzicu objęłoby przyszłych automatycznie, ale poszerza
  powierzchnię uprzywilejowaną (wątek #36). Prawdziwą naprawą klasy jest
  uzgadnianie zakresu — Etap 4 planu.
- **REV-021 — ZAMKNIĘTE przez recenzenta** (zaimplementowane w `1edca10`). Instalacja nie
  może skasować zadań, które cel już wykonuje (`assert_target_block_not_clobbered`),
  a linie „porzucone" przez render konta trafiają do bloku ogólnohostowego
  **tylko** jeśli są rozpoznane jako ogólnohostowe — reszta zatrzymuje migrację
  z podaniem linii. Odpowiedź: `docs/internal/reviews/responses/REV-20260801-021.md`.
- **REV-018/-019/-020 — ZAMKNIĘTE przez recenzenta** (zaimplementowane w `1d5a8c4`).
  Bramka duplikacji porównuje teraz **tożsamość zadań**, nie ścieżkę configu
  (`job_identity()` zdejmuje katalog skryptu i log, zostawia harmonogram,
  datasety, wzorzec, retencję, quiesce i progi). Doszedł czasownik
  `zfs-backup.sh migrate-to-account <konto> [--preflight] [--yes]` z pięcioma
  fazami REV-020 F3, a linie ogólnohostowe (digest) dostały własny blok
  `# BEGIN zfs-backup-host` w crontabie roota zamiast być luźną linią, której
  nikt nie jest właścicielem. Odpowiedzi: `docs/internal/reviews/responses/REV-20260801-018.md`,
  `-019.md`, `-020.md`.
- **Świadomie NIEzrobione z REV-020 F1, i recenzent to potwierdził:** faza
  `prepare` przenosi config, ale **nie nadaje** `zfs allow` ani grantu quiesce —
  wypisuje dokładną komendę `deploy.sh` i odmawia. REV-022 („Accepted progress",
  pkt 3) nazywa tę granicę właściwą: uprzywilejowany grant zostaje w `deploy.sh`,
  nie wchodzi do `migrate-to-account`. Brakowało natomiast samego polecenia dla
  konta lokalnego — patrz punkt niżej.
- **Brakująca droga nadania: DODANA** (`3831509`, doprecyzowana przez REV-022 w
  `32d6ed1`). `--allow-quiesce` działało wyłącznie z `--join`, czyli tylko dla
  peera; własne konto delegowane hosta nie miało żadnego polecenia, które
  nadałoby mu quiesce. Teraz jest to Faza 8h zwykłego przebiegu `deploy.sh`,
  z whitelistą wyprowadzoną z tej samej listy `--datasets`, co grant `zfs allow`
  — jedna zmienna, więc „może zamrozić" nie może przerosnąć „może replikować".
- **Faza 1 (`--preflight`) PRZETESTOWANA NA ŻYWO** na metropolis pve1
  (2026-08-01, `4662b8a`), tylko odczyt, oba crontaby bajt w bajt bez zmian po
  przebiegu. Wynik zgodny co do joty z ręczną analizą: config do przeniesienia,
  brak delegacji ZFS na dokładnie czterech datasetach pod `hdd/vm-disks`, brak
  grantu quiesce przy bloku używającym `-q`, i **1 linia ogólnohostowa** (digest)
  wyliczona, nie wpisana na sztywno. Pierwszy przebieg na żywo od razu znalazł
  własny błąd: faza 1 renderowała jako konto, zanim faza 2 przeniosła config,
  więc na jedynym kształcie hosta, dla którego to pisałem, kończyła się FATAL-em.
  Naprawione w `4662b8a`, trzy testy padają na bazie.
- **Fazy 2–5 PRZETESTOWANE NA ŻYWO** w oknie serwisowym za zgodą właściciela,
  metropolis pve1, 2026-08-01 17:07–17:09. Syntetyczny blok na datasecie
  testowym, nie produkcyjne zadania. Przeszło: config **przeniesiony** do
  `/etc/zfs-snapshot-all/`, blok kolektora zdjęty z roota, digest zachowany we
  własnym bloku `# BEGIN zfs-backup-host`, blok konta zainstalowany ze ścieżkami
  konta i finalną ścieżką configu w `# Source:`, wszystkie cztery linie konta
  wykonane jako konto. Potem przebieg z wstrzykniętą awarią (crontab konta
  ustawiony `chattr +i`): crontab roota odtworzony **bajt w bajt**, config
  cofnięty. Po teardownie oba crontaby identyczne ze zrzutem sprzed testu,
  dataset testowy usunięty, zero resztek.
- **Znalezione przez ten przebieg i naprawione:** rollback twierdził „both
  crontabs restored" linijkę po ostrzeżeniu, że crontaba konta nie odtworzył
  (`d506361`) — nigdy nie był zapisany, więc nie było czego odtwarzać.
- **Migracja produkcyjnego bloku metropolis pve1: WYKONANA 2026-08-01 18:10:47–18:10:49**,
  na polecenie właściciela, po nadaniu obu brakujących zdolności. Nie na
  syntetyku — na 15 żywych liniach zadań. Wynik: root 15 → 3 linie
  (`check-pool-capacity`, `--self-update`, digest w bloku `zfs-backup-host`),
  konto 1 → 13 (`git pull` + 12 zadań), config przeniesiony do `/etc/`.
  Wszystkie 12 linii konta uruchomione ręcznie **jako konto**: sendy i prune'y
  rc=0, monitory rc=0 na własnych progach, kolejka alertów pusta. Kopie obu
  crontabów i configu zdjęte przed operacją (host + scratchpad).
- **Co ten przebieg znalazł, a czego nie znalazł żaden test ani okno serwisowe:**
  lokalny quiesce jako konto delegowane zgłaszał trzy DZIAŁAJĄCE guesty jako
  „not running", robił snapshoty bez zamrożenia i kończył się zerem. Naprawione
  w `55d33a2`, po naprawie ten sam job faktycznie mrozi VM 106 i odmraża ją.
  Zobacz też okno zamrożenia w sekcji 3 — to drugi, jeszcze nienaprawiony wniosek
  z tego samego przebiegu.
- **Nieprzetestowane na żywo:** konto, które JUŻ ma rozłączny blok zarządzany
  (temat REV-021) — pokryte tylko testami na stubach.
- ~~Test `remove-client` celujący w crontab skonfigurowanego konta~~ — **zrobione**
  (sekcja 23 pakietu `zfsbackup`). Oba warunki z dodatkowej uwagi REV-019 padają
  na `9af0003`, czyli dokładnie tym commicie, w którym poprawka wylądowała w
  niewłaściwej funkcji, i przechodzą dziś.

### Czeka na werdykt recenzenta

- **REV-20260804-042** — drugi krąg werdyktu A-J: żaden nowy defekt kodu w
  REV-041, REV-039 F1 i REV-040 zamknięte przez recenzenta. Bramki G i I
  nadal **NOT RUN** na żywo — recenzent wprost zabronił zmiany kodu, żeby
  je „zaliczyć". Odpowiedź `docs/internal/reviews/responses/REV-20260804-042.md`:
  NEEDS-DISCUSSION dla obu, bo to pytanie o infrastrukturę (druga trasa
  sieciowa / nieklastrowana para hostów), nie o implementację — patrz
  „Czeka na decyzję właściciela" niżej.
- **REV-20260801-021** (`1edca10`, `99ba1f5`) — instalacja nie może skasować
  zadań, które cel już wykonuje; tylko rozpoznane linie ogólnohostowe zostają
  w crontabie roota. Odpowiedź w `docs/internal/reviews/responses/REV-20260801-021.md`.
- **REV-20260801-022 F1** (`32d6ed1`) — `--allow-quiesce` musi nazwać konto,
  które dostaje grant, i odmówić zamiast kończyć się zerem. Odmowa przeniesiona
  na czas argumentów, czyli mocniej niż wymagała recenzja. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-022.md`. **Nota produktowa recenzji
  (jeden przepływ zamiast trzech poleceń) przyjęta i NIEZROBIONA** — patrz
  „Czeka na decyzję właściciela".
- **`55d33a2` — nie z recenzji, ale wymaga tego samego spojrzenia.** Lokalny
  quiesce czytał „nie mogłem zapytać" jako „guest nie działa" i robił snapshoty
  bez zamrożenia, kończąc zerem. Naprawione przez nauczenie lokalnej ścieżki
  trasy przez helper (którą ścieżka zdalna miała od 2026-07-31) i przez
  odmowę zamiast degradacji.
- **REV-20260801-023** (`244ec0d`) — recenzent zauważył, że naprawiłem sondę i
  stanąłem: zostało **pięć** gałęzi, które nadal degradowały (guest już
  zamrożony, nieczytelny `fsfreeze-status`, freeze który nie wszedł, nieudany
  flush kontenera, tryb niepasujący do rodzaju guesta). Wszystkie odmawiają
  kodem 3 przed snapshotem. Nieudany thaw też kończy przebieg niezerowo i
  **zatrzymuje** guesta na liście odzysku zamiast go zapomnieć. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-023.md`. Piąta gałąź (tryb niepasujący)
  wykracza poza literę recenzji — zaznaczone tam wprost do ewentualnego
  odrzucenia.
- **REV-20260801-026** (`5ff1b0b`) — uprawnienia ZFS wyprowadzane z wyrenderowanych
  zadań, nie z typu sekcji; komunikat naprawczy z dokładną listą datasetów.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260801-026.md`.
- **REV-20260801-027** — to samo o jeden poziom wyżej: quiesce sprawdzany
  **per zadanie** przez prawdziwego helpera, jako konto, zamiast jednego
  hostowego „czy konto dosięga helpera". Zweryfikowane na żywo na wszystkich
  czterech hostach. Odpowiedź w `docs/internal/reviews/responses/REV-20260801-027.md`.
- **REV-20260801-024** (`be1cfe7` + `d8bb52a`) — okno zamrożenia jako termin, nie
  kolejność. Wszystkie pięć wymaganych zachowań, zmierzone na żywo: 18 s → 1 s.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260801-024.md`. Do zważenia przez
  recenzenta: budżet 5 s oznacza, że host z kilkoma wolno mrożącymi się gośćmi
  Windows w **jednym** zadaniu legalnie go przekroczy i to zadanie padnie —
  kierunek fail-closed, ale zmiana zachowania dla konfiguracji, której nikt
  jeszcze nie próbował.
- **REV-20260801-025** (`7564f8e` + `c7ce8da`) — granica quiesce'u ma objąć
  **każdą pulę** i **ścieżkę zdalną**. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260801-025.md`, **napisana z opóźnieniem i tak
  właśnie opisana**: F1 zostało bez pliku odpowiedzi, więc recenzent nie miał
  jak odróżnić „niesione" od „nieprzeczytane" i zapytał drugi raz jako REV-029.
- **REV-20260802-028** (`90a06c8`) — `--add-quiesce`: grant wyłącznie
  dokładający, idempotentny, fail-closed przy nieczytelnej whiteliście;
  `--allow-quiesce` nadal nadpisuje, bo dla **zapisu** to jest poprawne.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260802-028.md`.
- **REV-20260802-029** (`c7ce8da`) — powtórka REV-025 F1: granica sprawdzana
  przed **każdą** pulą, na obu ścieżkach. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-029.md`.
- **REV-20260802-030** (`9fbf1df`) — niekompletny zestaw quiesce jest
  **usuwany**, nie tłumaczony: rejestr tego, co przebieg utworzył, trzy wyjścia
  (komplet / nic nie zatwierdzono / **ROLLBACK INCOMPLETE**, kod 7, z nazwą
  każdego ocalałego snapshotu). Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-030.md`.
- **REV-20260802-031** (`3d4c13f`) — sam raport wycofania nie może zawieść
  fail-open. Drugi plik tymczasowy **usunięty**, nie obsłużony; nieudany zapis
  rejestru kończy się kodem 7 z nazwą snapshotu. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-031.md`.
- **REV-20260802-032** (`700d045`, `52ec5e6`) — nieudany zapis rejestru musiał
  rozliczyć **cały** zestaw, nie tylko nazwę, która akurat nie weszła. Rozwiązane
  **inaczej niż sugerowała recenzja**: nie drugim rejestrem na to, czego pierwszy
  nie pomieścił, tylko usunięciem pliku — rejestr jest tablicą, jak od zawsze na
  ścieżce lokalnej, więc klasa błędu znika zamiast być obsługiwana. Powód
  odstępstwa jest zmierzony i opisany w odpowiedzi: każda przenośna próba
  zepsucia pliku *między pulami* kasowała też **zapis wcześniejszej puli**.
  Odpowiedź w `docs/internal/reviews/responses/REV-20260802-032.md`. **Do zważenia przez
  recenzenta:** pięć nowych asercji, które padają na `HEAD~`, to asercje
  strukturalne — część behawioralna przypina kontrakt, ale nie rozróżnia wersji,
  bo stary defekt wymagał trybu awarii, którego już nie ma. Reprodukcja defektu
  jest w odpowiedzi zamiast w suicie.

- **Ujednolicenie pisarza crontaba — W TOKU, decyzja właściciela 2026-08-02.**
  Do dziś crontaby pisało **sześć miejsc** w trzech programach, z czego dwie
  linie (`check-pool-capacity.sh`, `update-control.sh --self-update`) leżały
  **poza jakimkolwiek blokiem**, nieodróżnialne od tego, co wpisał człowiek.
  Sześć asercji w `zfs-backup.sh` to kontrole kompensujące dokładnie ten stan.
  Uzgodniony model: **jeden pisarz, kilku zlecających** — `deploy.sh` posiada
  blok `zfs-backup-host`, warstwa zadań blok `zfs-backup-managed`, a prymityw
  przyjmuje nazwę bloku jako argument, więc „nie mogę tknąć cudzych linii"
  przestaje być regułą do zapamiętania i staje się własnością jedynego wejścia.
  **Plasterek 1 (`0a14a66`): `lib-cron.sh` + `test/cron`, żaden pisarz jeszcze
  nie przełączony. Plasterek 2: `zfs-backup.sh` przełączony** — jeden czytelnik
  (`cron_read`), jeden pisarz z odczytem zwrotnym (`cron_write`, czyli
  przywracanie crontaba przestaje móc kłamać) i jeden renderer bloku
  (`cron_block_render` zamiast lokalnego `awk`). Zachowanie bez zmian poza
  dodaną weryfikacją; `zfsbackup` 207/207, `cron` 49/49.
  **Plasterek 3: `gen-cron.sh --install` przełączony** — zostaje w nim tylko
  jego własna polityka (flock oraz odmowa instalacji obok luźnych linii
  `snapsend`/`delsnaps`/`check-snap-age`, gdy bloku jeszcze nie ma). Sprawdzone
  na żywo na metropolis pve1: render **starego i nowego kodu na produkcyjnym
  configu jest identyczny** przy tym samym `REPO_DIR`, `scenarios` 34/34 na
  hoście, `gencron` 56/56, `cron2conf` 10/10, `zfsbackup` 207/207.
  Zmiana zachowania warta odnotowania: dopasowanie markera było **dosłownym
  porównaniem** z `MARKER_BEGIN`, więc blok z innym ogonem nie zostałby
  rozpoznany i dopisałby się **drugi**; biblioteka dopasowuje po nazwie, więc
  taki blok jest adoptowany.
  **Plasterek 4 ZROBIONY I WDROŻONY na wszystkich czterech hostach
  2026-08-02 ~21:00.** `deploy.sh` przeszedł na prymityw, a dwie luźne linie
  (`check-pool-capacity.sh`, `update-control.sh --self-update`) oraz linia
  auto-pull konta zostały **przeniesione do bloku `zfs-backup-host`**, z
  zachowaniem treści i harmonogramów. Po wdrożeniu na każdym z czterech hostów:
  **zero luźnych linii zadań** poza blokami, liczba zadań bez zmian
  (root 3→3 wszędzie; konta 16→16, 12→12, 28→28, 8→8), crontaby zarchiwizowane
  przed operacją.

  Dwie rzeczy warte zapamiętania z tego plasterka. **Adopcja nie przepisuje
  treści** — kto przestawił capacity na 06:00, zachowuje 06:00; zmienia się
  wyłącznie miejsce, bo `deploy.sh` obiecuje „already present, leaving it
  alone". Wyjątkiem jest linia aktualizatora, która jest **normalizowana**, bo
  sensem jest sprowadzenie trzech historycznych pisowni do jednej. Oraz:
  warunek „już aktualna, zostaw" patrzył wyłącznie na **treść**, więc na każdym
  istniejącym hoście linia aktualizatora byłaby uznana za gotową i nigdy nie
  trafiłaby do bloku — złapane dopiero podglądem na żywym crontabie, nie w
  testach.

  **Model docelowy osiągnięty:** jeden pisarz (`lib-cron.sh`), dwóch
  zlecających (`deploy.sh` → `zfs-backup-host`, warstwa zadań →
  `zfs-backup-managed`), zero linii poza blokami.
  Robione **przed** enrollmentem, żeby nowe ścieżki instalacji crona nie
  powstawały w starym modelu.
- **REV-20260802-034** — recenzja **refaktoru crontabowego**, cztery findingi
  P1, **wszystkie przyjęte, żadnego sporu**. Dwa są skutkiem moich wczorajszych
  decyzji. **F1** (`cecfeaf`): `set_host_block` przepisywał **współdzielony**
  blok z własnego, częściowego spisu — po tym, jak `deploy.sh` dołożył tam
  updater i capacity, kolejna migracja skasowałaby oba, cicho, meldując
  zdrową migrację. Recenzent trafnie nazwał też mój test: zostawiał capacity
  **luzem** poza blokiem, więc podmiana całości wyglądała nieszkodliwie.
  **F4** (`cecfeaf`): walidacja markerów była lokalna dla nazwy, więc cudzy blok
  zagnieżdżony w docelowym przechodził i ginął w całości.
  **F2 ZROBIONE**: zamek per-użytkownik na każdym mutującym wejściu
  (`cron_lock_acquire`/`_release`, wariant `_multi` sortowany po nazwie —
  deadlock niemożliwy konstrukcyjnie), `test/cron` sekcje P–S (+14), przeplot
  **wymuszony barierą**, nie ścigany czasem. Przy okazji własny błąd tej samej
  klasy co się tu ściga: `local user="$1" fd="${CRON_LOCK_FD[$user]:-}"` — bash
  rozwija obie wartości w jednej komendzie `local` przed przypisaniem, więc
  `$user` w drugim polu odwoływał się do niczego pod `set -u`, a diagnoza szła
  w `/dev/null` linijkę niżej — suita padała bez żadnego komunikatu. Naprawione
  rozbiciem na dwie instrukcje.
  **F3 ZROBIONE** (`4f1c174`+`41afa2f`): `cron_replace_all`/`_impl` —
  zamek + walidacja markerów (F4) + `cron_write` z odczytem zwrotnym — i
  wszystkie trzy bezpośrednie wywołania `crontab` w `migrate-to-account`
  (forward, rollback-root, rollback-konto) przełączone na niego. Poprawiony
  własny błąd projektowy z odpowiedzi F2: transakcja migracji NIE trzyma
  obu zamków naraz — `gencron_as_target` odpala `gen-cron.sh` jako **osobny
  proces**, który sam bierze zamek konta; trzymanie go w rodzicu
  zakleszczyłoby się o własne dziecko. Zamiast tego: sekwencja osobno
  zamykanych operacji, porządkowana istniejącym `did_root`/`did_acct`.
  Po drodze złapany drugi błąd tej samej rodziny co F2: `exec {fd}>path
  2>/dev/null` i `eval "exec $fd>&-" 2>/dev/null` w `cron_lock_acquire`/
  `_release` — goły `exec` bez komendy stosuje WSZYSTKIE swoje przekierowania
  trwale do bieżącej powłoki, więc `2>/dev/null` nie gasił błędu tej jednej
  próby, tylko trwale kasował stderr całego procesu od tej linii w dół.
  Efekt: `test/zfsbackup/run.sh` sekcja 25 traciła cały tekst rollbacku
  (`warn`/`die`, oba na stderr) z przechwyconego `$(...2>&1)`, mimo że logika
  rollbacku liczyła się poprawnie (potwierdzone osobnym kanałem debug) —
  potwierdzone też na żywym Linuksie (`BASH_XTRACEFD` odizolowany od
  zepsutego fd 2 odzyskał cały ślad). Naprawione: `: >"$path" 2>/dev/null`
  (prawdziwa komenda, przekierowanie faktycznie zakresowe) jako sprawdzenie
  zapisywalności przed trwałym `exec`, zamknięcia bez `2>/dev/null` w ogóle.
  Testy: `test/cron` **120/120** (+9 T), `test/zfsbackup` **211/211**
  (sekcja 25 zielona), plus cały graf wpływu — także `sudo
  test/scenarios/run.sh` **34/34** na metropolis pve1 (root, prawdziwy
  `flock`). **ZAMKNIĘTE i zmergowane do `main` (`db2f7fe`)**, gałąź `cron-f3`
  skasowana lokalnie i na origin. Wszystkie cztery findingi (F1, F2, F3, F4)
  ACCEPTED/IMPLEMENTED. Jedyna otwarta luka: żaden żywy host nie ma dziś
  oczekującej migracji, więc `cron_replace_all` nie był jeszcze wywołany na
  prawdziwym produkcyjnym bloku — wszystkie cztery hosty migrowały się na
  kodzie sprzed F3.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260802-034.md`.
- **REV-20260803-036** — **CHANGES REQUIRED, ZROBIONE** (ten commit): pauza
  była tekstowym konwenansem, nie transakcją. Pięć findingów P1, wszystkie
  ACCEPTED/IMPLEMENTED: `--fullcron` zamieniał crontab PRZED durable
  zapisem stanu resume (F1, kolejność odwrócona + atomowy rename + rollback
  stanu przy nieudanym zapisie crontaba); tryb blokowy commitował blok po
  bloku, więc częściowy sukces zwracał `rc=0` (F2, teraz jeden render
  lokalny + jeden zapis przez `cron_replace_all_impl`); `--resume` sprawdzał
  obecność markera przez `grep`, nie dokładny kształt, więc placeholder z
  dopisaną linią cichо gubił tę linię (F3, teraz bajt-po-bajcie przeciw
  zapisanemu placeholderowi); `cron_block_names_present` traktowało KAŻDY
  syntaktycznie poprawny `# BEGIN name` jako nasz (F4, teraz jawny rejestr
  `PAUSE_KNOWN_BLOCKS`); i najważniejsze — pauza nie była egzekwowana przez
  wspólnego pisarza, więc zwykły `gen-cron.sh --install` (albo
  `cron_block_ensure_line`/`adopt_line`) mógł po cichu odtworzyć aktywny
  blok zaraz po tym, jak `--pause` zgłosiło sukces (F5, teraz
  `cron_paused_guard` w `lib-cron.sh` odmawia KAŻDEMU zwykłemu pisarzowi).
  Markery pauzy przeniesione z `deploy.sh` do `lib-cron.sh` jako
  `CRON_PAUSE_*` — jeden kanoniczny właściciel dla wszystkich trzech
  programów, które piszą crontaba. `pause` **74/74** (+25 nowych testów,
  sekcje O–V), pełen graf `./test/impact.sh`: **665/665** bez błędów
  (`cron` 123, `run.sh` 56, `join` 54, `quiescehelper` 119, `selfupdate`
  28, `zfsbackup` 211). **Żywe hosty:** `deploy.sh --self-update` uruchomiony
  na wszystkich 4 (pve0, pve1, metropolis pve1, metropolis pve2) — czysty
  fast-forward na każdym, crontab roota i konta na pve0 bajt-w-bajt
  identyczny przed/po (guard nie odpala się na zwykłym, niezapauzowanym
  crontabie). `test/pause/run.sh` (suita ze stubem, nie dotyka prawdziwego
  `crontab(1)`) na wszystkich 4: **73/74** wszędzie — jeden powtarzalny
  fałszywy fail (sekcja G zakładała brak konta delegowanego, a każdy z tych
  hostów je ma; `detect_delegated_account()` skanowała prawdziwy `/home/*`,
  czego ta rodzina testów nie stubowała). **Naprawione tego samego dnia:**
  skan jest teraz nadpisywalny przez `PAUSE_ACCOUNT_SCAN_GLOB` (ten sam wzorzec
  co `CRON_LOCK_DIR`/`PAUSE_STATE_DIR`/`CRONTAB_DIR`), suita wskazuje ścieżkę
  bez dopasowań — `pause` **74/74** ponownie. **Prawdziwy cykl
  `--pause`/`--resume` wykonany tego samego dnia**, z właścicielem obecnym
  w sesji, na metropolis pve2: oba konta (root + zfsbackup) zapauzowane,
  obce (już wyłączone) linie w crontabie roota nietknięte (F4 na żywo),
  `--resume` odzyskał oba konta bajt-w-bajt identycznie do stanu
  sprzed pauzy. Bonus: F5 zadziałał na żywo bez planowania — `--resume`
  najpierw odpala pełny przebieg `deploy.sh` (fazy 1-7), a DOPIERO POTEM
  swój dispatch resume; dwa zwykłe zapisy w tym przebiegu (linia
  auto-update, linia capacity) trafiły na wciąż zapauzowany blok i zostały
  poprawnie odrzucone, zanim resume je przywrócił chwilę później —
  dokładnie scenariusz „forced interleaving" z recenzji, tyle że w jednym
  wywołaniu zamiast dwóch procesów. `sudo ./test/scenarios/run.sh`
  uruchomiony tego samego dnia na pve2 — **34/34**, scratch dataset
  posprzątany przez własny EXIT trap suity. **Domknięta luka zakresu F5:**
  `migrate-to-account` commituje przez `cron_replace_all`, ten sam prymityw
  co pauza/resume, celowo NIE owinięty `cron_paused_guard` (bo inaczej
  pauza odmawiałaby sama sobie) — co zostawiało migrację bez ochrony przed
  cichym nadpisaniem aktywnej pauzy. Naprawione bez dotykania wspólnego
  prymitywu: `cmd_migrate_to_account` sprawdza oba crontaby
  (`cron_fullcron_paused` + `cron_block_paused` dla `zfs-backup-managed`
  i `zfs-backup-host`) na starcie preflight, przed jakąkolwiek pracą.
  `zfsbackup` **214/214** (+3, sekcja 35). **Luka zgodności placeholdera
  sprzed `bc84746`** sprawdzona na żywo na wszystkich 4 hostach — żaden nie
  ma i nigdy nie miał `/root/.zfs-snapshot-all-pause-state` (funkcja nigdy
  nie była użyta produkcyjnie przed tą sesją) — shim migracyjny świadomie
  odrzucony jako złożoność dla przypadku, który nigdy się nie zdarzył.
  **Atomowa pauza całej floty (root+konto razem) świadomie odrzucona**:
  nigdy nie wymagana przez recenzję (kryteria F2 są sformułowane per-user),
  dziś nigdy nie cicha (każda tożsamość zgłasza swój błąd po imieniu), a
  jedyny osiągalny stan mieszany po przebudowie F2 to "jedna strona
  zapauzowana, druga nie" — nie częściowa korupcja. `cron_lock_acquire_multi`
  zostaje nieużywany, gdyby przyszły incydent zmienił ten osąd.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260803-036.md`.
- **REV-20260803-035** — **CHANGES REQUIRED, ZROBIONE** (`9e977f6`): zamek
  F2 był kluczowany ścieżką zależną od **tożsamości wywołującego**.
  `CRON_LOCK_DIR` = `/run` jeśli zapisywalny, inaczej `$TMPDIR`/`/tmp` — root
  zawsze widzi `/run` jako zapisywalny, delegowane konto zwykle nie, więc
  root blokował `/run/lib-cron.<user>.lock`, a `gen-cron.sh` uruchomiony
  jako to samo konto blokował `/tmp/lib-cron.<user>.lock` **na tym samym
  crontabie**. Dwa różne zamki na jednym pliku to brak zamka — dokładnie
  wyścig F2, który miał być zamknięty. Testy P–S z REV-034 nie mogły tego
  złapać, bo obie strony testu dostają ten sam `CRON_LOCK_DIR` z zewnątrz.
  Naprawione: jeden stały katalog `/var/lib/zfs-snapshot-all/locks`
  (`$ALERT_SHARED_DIR`, ta sama obróbka 2775 root:zfsalert co kolejka
  alertów), bez żadnego fallbacku — niedostępny katalog odmawia, nie wybiera
  po cichu innego miejsca. Dodana też ochrona przed symlinkiem na
  przewidywalnej ścieżce blokady. `cron` **123/123** (+8, 5 SKIP na tej
  maszynie — bity uprawnień i symlink wymagają prawdziwego Linuksa).
  **Nie sprawdzone tutaj:** prawdziwy `flock` między realnym procesem roota
  a realnym procesem konta na tym samym hoście — wymaga żywego hosta,
  zgłoszone jako zobowiązanie ręczne (Faza 4 jest idempotentna, więc
  najbliższy `deploy.sh` na dowolnym hoście to podejmie za darmo).
  Odpowiedź: `docs/internal/reviews/responses/REV-20260803-035.md`.
- **REV-20260802-033** — recenzja **projektowa**, nie defektowa: uproszczony
  enrolment ma odkrywać dane **na źródle**, trzymać jeden edytowalny plik
  zakresu i odróżniać endpoint od trasy. Recenzja wprost zabrania
  implementowania czegokolwiek przed odpowiedzią. Odpowiedź w
  `docs/internal/reviews/responses/REV-20260802-033.md`: **wszystkie pięć findingów
  ACCEPTED**, F3 i F5 z naddatkiem.
  Poprzedziła ją rozmowa właściciel ↔ implementer — dziesięć uzgodnień spisanych
  w `docs/discussions/ENROLMENT-AGREED-2026-08-02.md`, m.in. edycja pliku na
  pve2, granty osobną komendą, zawężenie odbierające tylko własne granty, sync
  odrzucany między węzłami tego samego klastra, jeden aktualny endpoint zamiast
  slotów `lan`/`vpn`, oraz online bez żadnej nowej usługi.
  **Do zważenia przez recenzenta:** inwentaryzacja pokazuje, że szew z F1 jest
  mniejszy, niż zakłada recenzja — format paczki **już dziś** toleruje brak
  zakresu (`PEER_CONF_DATASETS` nie jest kluczem wymaganym, pętla grantów nie
  robi nic na pustej liście, `--draft-config` radzi sobie z pustym manifestem).
  Nowy jest wyłącznie drugi akt: finalizacja nadająca granty z edytowanego pliku.

  **Plasterek 1 ZROBIONY** (`ff712df`): `lib-scope.sh` — gramatyka, czytnik
  (`scope_read`) i decyzja `scope_includes`, plus cztery walidatory `pc_is_*`
  przeniesione z `deploy.sh`. `scope` **34/34**.
  **Plasterek 2 ZROBIONY** (`4190d83`): `--join` przestaje nadawać dla peera
  pull — konto i klucz bez żadnych uprawnień ZFS. Nowa, osobna komenda
  `--commit-scope=<label>` czyta plik zakresu, przechodzi realnymi
  potomkami każdego korzenia (`zfs list -r`, nie dziedziczeniem `zfs allow`,
  bo dziedziczenie nie ma odpowiednika „odmowy" dla `exclude_tree`) i nadaje
  dokładnie to, co `scope_includes` wybiera; `--allow-quiesce` przeniesione
  tu razem z nadaniem. `--commit-scope-check=<label>` to sama walidacja
  formatu (manifest, rola, `as`, parsowanie) bez `zfs` i bez roota — ten sam
  kształt co `do_join_check`, i z tego samego powodu: to czyni połowę
  formatową testowalną wszędzie. Peer root i push — bez zmian.
  Testy: `join` **54/54** (+12), `quiescehelper` **119/119** (jedna asercja
  dopasowana do nowej klauzuli), `zfsbackup` 211/211, `selfupdate` 28/28.
  **Nie sprawdzone tutaj:** sam przebieg `zfs list`/`zfs allow` na realnej
  puli — wymaga żywego hosta ze świeżym `--join`/`--commit-scope`, żaden
  istniejący peer nie jest w stanie sprzed tego plasterka. Zgłoszone jako
  zobowiązanie ręczne, tym samym kształtem co ryzyko F3 w REV-034.
  Odpowiedź: `docs/internal/reviews/responses/REV-20260802-033.md` (addendum
  2026-08-03).
- **REV-20260731-011 §2 — spór.** Zakwestionowałem tezę, że ścieżka błędu
  `mkdir allow_dir` nie wywołuje rollbacku: wywołanie jest tam od `763767b`,
  dowód przez `git show 7dc4a98:deploy.sh`. Zgodziłem się warstwę niżej
  (`created_dir=0` zostawiał pusty katalog) i to naprawiłem w `5fec1f4`.
  Recenzent nie odniósł się do tego wprost w późniejszych recenzjach.

### Czeka na decyzję właściciela

- **NOWE (REV-20260804-042): Bramki G i I potrzebują infrastruktury, nie
  kodu.** Dostępne dziś cztery hosty to dokładnie dwa dwuhostowe klastry
  Proxmox (pve0/pve1 na 192.168.11.x, metropolis pve1/pve2 na
  192.168.28.x), każda para ma dokładnie jedną trasę sieciową między sobą,
  a oba VPN-y klastrów są wzajemnie nieosiągalne (patrz punkt REV-039/F4
  wyżej). Bramka G (zmiana trasy przy zachowanym endpointcie) i bramka I
  (sync na nieklastrowanej parze) nie mają więc gdzie się wykonać na
  prawdziwej infrastrukturze. Trzy opcje wypisane w
  `docs/internal/reviews/responses/REV-20260804-042.md` dla każdej bramki osobno:
  (a) dostawić prawdziwą drugą trasę/piąty host, (b) autoryzować
  odizolowane środowisko laboratoryjne na istniejącym hoście (kontenery/
  network namespace, bez dotykania produkcyjnej sieci klastra), albo
  (c) świadomie przyjąć lukę i przestać ją traktować jako blokującą.
  Żadna opcja nie wymaga zmiany kodu produkcyjnego.
- ~~Jeden przepływ zamiast trzech poleceń~~ — **ROZSTRZYGNIĘTE 2026-08-02:
  opcja (b).** Uprzywilejowany grant zostaje osobną, świadomą komendą;
  `migrate-to-account` wypisuje **jeden uporządkowany blok naprawczy** zamiast
  składać go za operatora, i sprawdza zdolności **ponownie tuż przed zapisem
  crontabów**. Opcję (c) — żeby wrapper sam wołał `deploy.sh` — odrzucono:
  jego najgorszy dzisiejszy błąd przepisuje crontab (odwracalne), po (c)
  poszerzałby grant (nikt nie zauważy). Granica `zfs-backup.sh`/`deploy.sh`
  z REV-020 F1 zostaje tam, gdzie była.

- ~~Ścieżka zdalna (`snapget -q`) bez ponownego odczytu i terminu~~ —
  **DOCIĄGNIĘTA 2026-08-02** (`7564f8e`): kolejność, ponowny odczyt na granicy,
  termin i odmowa przy nieczytelnym `fsfreeze-status`. Thaw był tam gwarantowany
  od początku (trap EXIT + deadman).
- ~~DŁUG: `snapsend`, `scenarios`, `remote` nieuruchomione~~ — **SPŁACONY
  2026-08-02 12:00–12:45.** `remote` 145/145 **dwukrotnie** — jako root i jako
  konto delegowane (to drugie z `--local-parent rpool/data`, bo domyślny scratch
  `rpool` jest pisany pod roota, a konto ma delegację tylko niżej). `snapsend`
  202/202, `scenarios` 34/34 na metropolis pve1.
- ~~Klaster 192.168.11.x bez kampanii `remote`~~ — **ZROBIONE 2026-08-02**, po
  sprawdzeniu replikacji i za zgodą właściciela. `remote` 145/145 pve0 → pve1
  (11.11), z `--peer-parent rpool`. Replikacja pvesr zweryfikowana przed
  uruchomieniem: zadania 100-0 i 106-0 co 2 h, FailCount 0, ostatni sync 14:00,
  a na pve0 wszystkie trzy repliki niosą snapshot `__replicate_*` z tej samej
  godziny — czyli obie maszyny z 11.11 dają się podnieść z hosta zapasowego.
  **Osobno do wiedzy: zadanie 101-0 (pve0 → pve1) jest WYŁĄCZONE od
  2023-10-26**, FailCount 6, ostatni sync sprzed prawie trzech lat. To druga
  strona relacji i nie dotyczy zabezpieczenia 11.11, ale VM 101 na pve0 nie ma
  repliki na sąsiedzie — tylko snapshoty retencyjne u siebie.
- ~~Luka parzystości: kampania na 11.x tylko jako root~~ — **ZAMKNIĘTA
  2026-08-02, decyzją właściciela.** Między kontami `zfsbackup` na pve0 i pve1
  (11.11) nie było zaufania ssh; oba miały już parę kluczy ed25519 z
  `deploy.sh`, brakowało wyłącznie `authorized_keys` i `known_hosts`.
  Ustanowione **dwukierunkowo**, w kształcie identycznym z metropolis (zwykły
  wpis, bez `command=`), a klucz hosta pobrany z `/etc/ssh/ssh_host_ed25519_key.pub`
  sąsiada **przez zaufany kanał roota**, nie `ssh-keyscan` — żadnego ślepego
  TOFU. `remote` **145/145** jako konto, `--local-parent rpool/data
  --peer-parent rpool/data` (oba hosty delegują kontu dokładnie ten dataset,
  z tym samym zestawem 11 czasowników co metropolis).
  **Cztery hosty mają teraz ten sam stan:** blok na koncie delegowanym, grant
  quiesce, config w `/etc/zfs-snapshot-all/`, zaufanie ssh między kontami pary
  i kampania `remote` przechodząca jako root **i** jako konto.
- ~~Ścieżka zdalna bez ponownego odczytu i terminu~~ — **DOCIĄGNIĘTA**
  (`7564f8e`), a granica objęła **każdą pulę** (`c7ce8da`, REV-029), niekompletny
  zestaw jest **usuwany** (`9fbf1df`, REV-030), a raport wycofania nie może już
  zawieść fail-open (`3d4c13f`, REV-031).
- ~~Czy migrować pozostałe hosty~~ — **ZROBIONE 2026-08-01/02: wszystkie
  cztery.** pve2 21:44, pve1 192.168.11.11 23:02, pve0 23:05. Każdy host ma
  własne konto delegowane, grant quiesce i config w `/etc/zfs-snapshot-all/`.
  Pierwszy nocny przebieg pod cronem przeszedł na wszystkich, z potwierdzeniem
  zamrożenia na granicy snapshotu (okna 1–4 s przy budżecie 5 s).
- ~~pve2: `[prune-bookmarks:rpool]` szerszy niż delegacja~~ — **ZAŁATWIONE
  2026-08-02, zawężeniem zakresu, nie poszerzeniem grantu.** Pod `rpool` na
  pve2 są dokładnie dwa poddrzewa (`rpool/ROOT/pve-1`, `rpool/data`) i oba są
  już delegowane; sam `rpool` nigdy nie trzyma bookmarków, bo bookmark powstaje
  wyłącznie na datasecie **wysyłanym**. Alternatywą było nadanie kontu pełnego
  jedenastoczasownikowego zestawu na `rpool`, czyli `destroy` nad całą pulą
  root, dla jednego prune'a. Zweryfikowane: zmieniony wyłącznie zakres w jednej
  linii crona, prune jako konto rc=0, liczba bookmarków bez zmian (4+3), survey
  zdolności czysty. Config w `zfs-cron-configs` `6cf289b`.
- **Dysk w pve1 (192.168.11.11).** Lustro `rpool` na jednym NVMe od
  2026-04-16, host z vsql2, jedyna pula na maszynie. Największa otwarta rzecz
  w projekcie i jedyna, której nie da się rozwiązać kodem.
- **`qemu-guest-agent` w VM 102 (`neth`) na metropolis pve1.** Nie działa
  wewnątrz gościa mimo `agent: 1`, więc maszyna dostała `quiesce = no`.
  Zainstalowanie agenta pozwala zdjąć tę jedną linijkę z configu.
- ~~metropolis pve2 nie ma pliku configu swojego crona~~ — **ZAŁATWIONE
  2026-08-01 21:32.** 14 produkcyjnych linii wskazywało
  `# Source: /root/gfs-install-tmp/jobs.pve2.v4.conf`, a tego katalogu nie było.
  `cron2conf.sh` odtworzył config z żywego crontaba, round-trip przez
  `gen-cron.sh` dał 12/12 linii bajt w bajt w tej samej kolejności, i dopiero
  wtedy plik został zainstalowany w `/etc/zfs-snapshot-all/jobs.pve2.v4.conf`.
  Crontab przed/po różnił się wyłącznie linią `# Source:` — liczba linii zadań
  bez zmian, 14 = 14. Guard z `c6c98c2` nie był naruszony: narzędzie nadal nie
  tworzy tego pliku samo, zrobił to człowiek po obejrzeniu diffa.
- ~~Config wewnątrz checkoutu gita~~ — **ZAŁATWIONE NA WSZYSTKICH CZTERECH
  HOSTACH 2026-08-01/02.** Configi leżały w `zfs-snapshot-all/`, nietrackowane
  i ignorowane, gdzie jedno `git clean -xdf` kasowało jedyny zapis zadań
  produkcyjnych. Każda migracja **przeniosła** swój config do
  `/etc/zfs-snapshot-all/` — nie skopiowała, więc nie ma dwóch ścieżek
  opisujących jedną pracę. Kopie są też w prywatnym `zfs-cron-configs`.
- ~~VM 102 (`neth`) na metropolis pve1 nie ma żadnego zadania snapshotowego~~ —
  **ZAŁATWIONE 2026-08-01 23:23.** Miała wyłącznie replikację pvesr `sun 01:00`
  i zero snapshotów retencyjnych: jedna kopia na pve2, nadpisywana co niedzielę,
  najgorszy punkt odtworzenia siedem dni, zero historii. Dostała te same cztery
  szablony co sąsiedzi (24/7/4/6), ale z `quiesce = no` — patrz punkt o agencie
  wyżej.
- **Korelacja per przebieg dla SQL** (REV-010 §2): odczyt najwyższego
  `EventRecordID` przed freeze i tylko nowych zdarzeń po thaw, wewnątrz jednej
  operacji zdalnej `snapget -q`. To nowa powierzchnia uprzywilejowana.
- **`--require-engaged` / `verify-sql-quiesce`** (REV-010 §3): tryb fail-closed,
  ma wejść razem z pierwszym konsumentem, nie wcześniej.
- **Uproszczenie UX wdrożenia — kryterium recenzenta, wciąż niespełnione**
  (REV-014): zwykły administrator Linuksa/ZFS ma używać **jednego** wysokopoziomowego
  przepływu enroll/remove, bez znajomości `pair`, `join`, wewnętrznych plików
  grantu i flag backendu. Akceptacja transakcji grantu **nie** czyni remote
  quiesce właściwym domyślnym ustawieniem uproszczonego wdrożenia. Powiązane z
  `docs/discussions/DEPLOY-UX-AGREED-POSITION.md`.
- **`PAIRING-DESIGN.md` Wariant B** — nadal propozycja, nie kod.
- **Automatyczna instalacja draft-configu** bez przeglądu administratora —
  odłożona.

### Znane luki, nie planowane do zamknięcia teraz

- **Test odtworzenia vsql2.** Jedyna rzecz, która dowodzi, że snapshot się
  przywraca — `engaged` z `sqlfreeze` mówi tylko, że SQL uczestniczył. Nie
  wykonany; **właściciel wykonuje go ręcznie** (decyzja z 2026-07-31), więc nie
  jest to pozycja zapomniana ani czekająca na implementera.
- **Trwałość wobec zaniku zasilania.** `rename` jest atomowy, nie trwały. Wobec
  `kill -9` i OOM projekt jest kompletny; wobec zaniku zasilania opiera się na
  systemie plików (ZFS transakcyjny, ext4 zrzuca dane przed rename na istniejący
  plik). Świadomie bez `sync`. To jest ocena, nie dowód.
- **Zamrożenie guesta na żywo** — instalacja grantu jest już przetestowana
  end-to-end (sekcja 1), ale freeze/thaw na produkcyjnym guescie nadal nie.
  VM 106 na metropolis pve1 to produkcyjny Windows `vbim2`; wymaga osobnej
  decyzji.
- **Ścieżki awarii i crash na żywym hoście** — na produkcji przeszedł happy
  path; wymuszone błędy `install`/`mv` i SIGKILL zostają w piaskownicy.
- **`-q` poza profilem `standard`** `zfs-backup.sh`, dopóki recenzent nie zamknie
  pozycji cyklu życia.
- **P2 dług testowy kontrolera aktualizacji** z uzgodnienia 2026-07-30: brak
  deterministycznego testu łączącego nieudaną aktualizację po `--resume-updates`
  z jednoczesną awarią ponownego zapisania holda; nie każdy caller prymitywów
  state/hold ma osobny scenariusz fault-injection. Otwierać ponownie przy
  materialnej zmianie `write_state_file()`, `remove_state_file()`,
  `emergency_disable()`, `do_self_update()`, `do_rollback()`, `do_resume_updates()`.

## 7. Aktualizacja i rollback

Kontroler `/root/.zfs-snapshot-all-update-state/update-control.sh` jest
instalowany **poza** checkoutem Git, więc cofnięcie repozytorium nie cofa kodu
egzekwującego hold. Cron wywołuje go bezpośrednio. `emergency_disable()` jest
fail-closed.

**Obowiązkowa zasada wydania:** zmiana `update-control.sh` wymaga po pobraniu kodu
pełnego `bash /root/scripts/zfs-snapshot-all/deploy.sh` na każdym hoście. Godzinny
self-update aktualizuje checkout, ale celowo nie nadpisuje kontrolera, który
właśnie działa.

## 8. Uzgodniony workflow

1. Właściciel wskazuje następny problem lub etap.
2. Implementer implementuje i testuje, obecnie bezpośrednio w `main`.
3. Każda materialna zmiana to osobny, czytelny commit z dowodami testów.
4. Recenzent wykonuje niezależną recenzję kodu, testów i skutków operacyjnych.
5. **Implementer odświeża ten dokument na końcu etapu**, przed zgłoszeniem go jako
   zrobiony, żeby obie strony patrzyły na ten sam stan.
6. Implementer nie zamyka findingów — zamknięcie techniczne należy do recenzenta.
7. Zamkniętych ustaleń nie otwieramy bez nowego dowodu regresji albo zmiany
   założeń.
8. Testy na żywych hostach używają sandboxów i porównania before/after wszędzie,
   gdzie mogą dotknąć crona, uprawnień albo prawdziwych datasetów.

Poprzedni uzgodniony punkt bazowy `388a78e` (2026-07-30) pozostaje ważny jako
zapis tego, co zostało wtedy wspólnie przyjęte. Ten dokument opisuje stan
bieżący; historia decyzji żyje w `docs/internal/reviews/` i `docs/internal/reviews/responses/`.
