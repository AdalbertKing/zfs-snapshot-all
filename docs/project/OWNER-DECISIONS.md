# Owner decisions

This file is the escalation queue for decisions that Claude and the Reviewer cannot resolve technically between themselves.
It is **not** a review-state ledger and must never duplicate `REVIEW_LEDGER.md`.

## Escalation rule

A disagreement between Claude and the Reviewer is not automatically an Owner question.

Before escalation, both agents must use the existing REV/response discussion channel to:

1. state the disputed claim precisely;
2. provide code, tests, documentation, operational evidence or a reproducible counterexample;
3. answer the other side's strongest argument;
4. identify whether the disagreement can be decided by repository facts, tests, existing architecture, safety policy or project goals already recorded in the repo.

If evidence resolves the disagreement, the agents record the consensus in the existing artifact and continue. The Owner is not asked to arbitrate ordinary technical review.

Escalate here only when a real choice remains that requires Owner authority, for example:

- product or architecture direction with two technically valid alternatives;
- priority or scope trade-off;
- acceptance of operational/security/compatibility risk;
- intentional breaking change;
- defer-versus-fix decision;
- release/deployment timing where evidence alone cannot decide.

An escalation entry must be short and decision-ready: the question, Claude's preferred option, Reviewer's preferred option, agreed facts, material consequences of each option, and a recommended default if the Owner chooses not to expand the discussion.

Transient disagreement, wording disputes, review bookkeeping, or lack of synchronization must never be escalated to the Owner.

## Open decisions

None.

## Currently queued

Carried over from the pre-V2 thread table. Each is a real choice that repository
facts cannot settle.

| # | Item | Whose move |
|---|---|---|
| 8 | PR #4 — a SECOND implementation of logical pause | owner: confirm the close, or say what else to salvage |
| 9 | Issue #3 — enrolment contract consensus | owner+reviewer |
| 11 | Profiles + live recursion (backlog) | owner |
| ~~14~~ | ~~`docs/OPS_MONITORING.md` untracked~~ | **ROZSTRZYGNIETE 2026-08-09, patrz nizej** |
| 15 | Two sessions built the same feature the same day | owner: decide how parallel sessions announce what they are taking |
| 36 | Grants on pve0 are per-dataset, not on the parent | owner: per-dataset (today) or parent grant |
| ~~32~~ | ~~Plan: method + stages~~ | **ROZSTRZYGNIETE 2026-08-09 — `ACTIVE-WORK-PLAN.md`** |
| 29 | Engine CLI / profiles / restore — design discussion | owner+reviewer: discuss |
| 30 | Atomic restore point — measured, and one gap | owner+reviewer: accept into the pre-freeze engine slice |

---

## ROZSTRZYGNIETE 2026-08-11 — jednorazowa autoryzacja edycji nagłówka verdict REV-104 (REV-105)

**Kontekst.** Recenzent zamknął REV-20260811-104 (napisał
`closures/REV-20260811-104.md`, `closed-by 0e29dcd`), ale nie zmienił nagłówka
`REV-20260811-104.md` z `CHANGES-REQUIRED`/`49d547a` na `APPROVED`/`0e29dcd`.
reviewctl policzył wtedy REV-104 jako **INVALID** ("closure without a matching
APPROVED verdict"), a `--verify` był czerwony bez naprawy po stronie implementera:
regeneracja ledgera nie czyści twardego błędu, a mój response już wskazywał
`0e29dcd`, więc nie było do czego wyrównać.

**Charakter edycji `f149455` (REV-105, przyjęte kryterium 2).** W sesji właściciel
polecił poprawić nagłówek, ale — jak słusznie wskazał recenzent w REV-105 —
zapis takiego polecenia autorstwa implementera NIE jest niezależną, audytowalną
prowenancją, więc nie powołuję się na niego jako na dowód. Zgodnie z kryterium 2
finding-u: `f149455` traktuję jako **jednorazową naprawę synchronizacyjną**
(nagłówek `REV-20260811-104.md` wyrównany do `APPROVED`/`0e29dcd`), której wynik
SEMANTYCZNY został od tego czasu **niezależnie ratyfikowany przez recenzenta** jego
własną determinacją closure (`closures/REV-20260811-104.md`, `closed-by 0e29dcd`).
Nie jest to precedens ani stałe pozwolenie.

**Reguła na przyszłość (REV-105).** Korekty `verdict`/`reviewed-implementation` w
plikach `REV-*.md` należą do RECENZENTA; implementer NIE edytuje metadanych werdyktu
recenzenta bez odrębnego, niezależnie audytowalnego wyjątku właściciela zapisanego
TUTAJ. Domyślnie taki rozjazd (closure bez APPROVED) zostaje zgłoszony recenzentowi
do samodzielnej naprawy.

---

## ROZSTRZYGNIETE 2026-08-08 — czym jest zabezpieczenie na tym poziomie

Implementer zmierzyl, ze 24 z 29 zadan we flocie tylko snapshotuje, a wszystkie
5 pozostalych ma cel LOKALNY, i przedstawil to jako luke: "w tej flocie nie ma
ani jednej kopii poza host".

**Wlasciciel: to jest bledna przeslanka, nie luka.**

> Nikt nie powiedzial, ze zabezpieczenie to wyslanie poza host. Nie na tym
> poziomie taka ocena. Host moze miec druga pare dyskow i na niej oddzielny pool
> (tu `hdd`), i wyslanie tam snapshotow z `rpool/data` jest zabezpieczeniem.
> Replika zalatwia tu transfer miedzyhostowy.

Warstwy sa rozdzielone i kazda robi swoje:

| warstwa | przed czym chroni |
|---|---|
| snapshot lokalny | skasowanie pliku, blad w maszynie |
| kopia na DRUGA PULE tego samego hosta | utrata puli / pary dyskow |
| pvesr | smierc hosta |

Zmierzone i zgodne z tym wzorcem: `rpool/data/*` -> `hdd/backups/*` na pve2
i pve0 to kopie MIEDZY PULAMI. 11.x pve1 ma tylko jedna pule (`rpool`), wiec
kopia miedzypulowa jest tam fizycznie niemozliwa.

**Konsekwencja dla narzedzi:** `--reconcile` NIE dostaje pojecia "poziomu
ochrony" i nie ocenia, czy zabezpieczenie jest wystarczajace. Taka ocena jest
architektoniczna i nie nalezy do audytu zakresu. Propozycja implementera, zeby
rozdzielic "snapshot lokalny" od "kopia poza hostem" jako klasy w raporcie,
jest **odrzucona** — zaszywalaby opinie polityczna w mechanizmie, ktory ma
raportowac fakty.

Audyt odpowiada na pytanie "czy cokolwiek to obejmuje", nie "czy to wystarczy".

---

## ROZSTRZYGNIETE 2026-08-08 — hdd/isos na pve0

Fakty: 16 GB, zamontowany, uklad magazynu katalogowego Proxmoksa
(`dump/`, `private/`, `template/`), zalozony 2019-09-18, zero snapshotow, zadne
zadanie go nie obejmuje.

**Wlasciciel: bez kopii — na liste ignorowanych.** Obrazy instalacyjne i
szablony sa do pobrania ponownie.

**Status wykonania: NIEZROBIONE, i to swiadomie.** Mechanizmu listy
ignorowanych jeszcze nie ma. Nie buduje go teraz z dwoch powodow:

1. recenzent uwarunkowal go wprost: jawna lista ignorowanych jest do rozwazenia
   **dopiero gdy sam detektor bedzie poprawny**, a REV-20260808-074 jest wciaz
   otwarta wlasnie na jego poprawnosci (dwie wady w klasyfikacji i parsowaniu
   flag znalezione tego samego dnia);
2. ksztalt mechanizmu to **zmiana schematu CONFIG v4** albo nowy plik obok
   niego, a to decyzja projektowa, nie szczegol implementacyjny.

### Propozycja do rozstrzygniecia (wlasciciel + recenzent)

| wariant | za | przeciw |
|---|---|---|
| nowa sekcja `[ignore:<dataset>]` w CONFIG v4 | jedno zrodlo prawdy, ten sam plik co reszta polityki, `cron2conf` i migracje juz go widza | poszerza schemat, ktory wlasnie zamrozilismy pojeciowo; kazdy konsument configu musi ja umiec pominac |
| osobny plik `/etc/zfs-snapshot-all/reconcile-ignore`, jeden dataset na linie | zero zmian w schemacie, czytelne dla czlowieka, latwe do wersjonowania | drugi plik do utrzymania i do wdrozenia na hosty |

Sklaniam sie do **drugiego**: audyt zakresu to nie polityka kopii, wiec jego
lista wyjatkow nie musi mieszkac w pliku polityki — a schematu nie ruszamy w
momencie, gdy detektor jest jeszcze recenzowany.

Do czasu rozstrzygniecia `hdd/isos` **pozostaje zglaszany** przez `--reconcile`.
Zapisane tutaj, zeby decyzja nie zyla wylacznie w rozmowie.

---

## ROZSTRZYGNIETE 2026-08-08 — cel w tej samej puli przy `add-local`

**Wlasciciel: wariant B — podac sam fakt, raz, w podgladzie, bez werdyktu.**

```
Uwaga: cel hdd/backups jest w tej samej puli co zrodlo hdd/vm-disks.
```

Bez „czy na pewno", bez flagi do obejscia, bez tlumaczenia przed czym to chroni.
**Nic z tego nie trafia do `--reconcile`** — tam obowiazuje wczesniejsze
rozstrzygniecie w calosci: audyt nie ocenia wystarczalnosci.

Uzasadnienie rozdzialu: podglad to nie audyt. Audyt chodzi w nocy i nie moze
moralizowac; podglad to jednorazowy ekran dla czlowieka w momencie wyboru.

**Osobno i niezaleznie od tego: cel ZAGNIEZDZONY w zrodle jest ODRZUCANY.**
To wada poprawnosciowa, nie polityka. Zmierzone, bo pierwszy opis mechanizmu
byl bledny: pierwszy przebieg konczy sie `rc=0`, drugi zglasza
`Transfer failed` i **mimo to** tworzy kolejny poziom zagniezdzenia. Kazdy
przebieg kopiuje poprzednia kopie do nowej — narastanie bez granicy, podane jako
zwykla awaria transferu. Dzis nic tego nie pilnuje.

---

## ROZSTRZYGNIETE 2026-08-09 — decyzja #14, `docs/OPS_MONITORING.md` usuniety

**Wlasciciel: „jesli to zalega i nie jest terenem naszych prac biezacych, to usun".**

Warunek sprawdzony przed usunieciem, bo plik byl NIESLEDZONY i skasowanie go
jest nieodwracalne — nie ma historii gita do odzyskania:

- **rutyna, ktora autoryzowal, nie istnieje**: zero wpisow crona pasujacych do
  monitoringu, ani u roota, ani na koncie delegowanym;
- **nic w repozytorium go nie konsumuje**: trzy odwolania to wylacznie wpisy
  „decyzja otwarta" (ten rejestr, plan, PROJECT_STATUS) plus zdanie w domknietej
  REV-052, ze to osobna decyzja wlasciciela.

Plik nie byl smieciem — byl dokumentem autoryzacyjnym: *"standing authorization
for what the daily routine may do without asking the owner first; anything not
listed here is a report, never an action"*. Dlatego jego SUBSTANCJA jest
zachowana tutaj, zanim plik zniknal.

### Bialy lista automatycznych napraw, jaka opisywal

Tylko te cztery, i nic wiecej, mialy dziac sie bez pytania:

1. zawieszony/przestarzaly proces skryptu monitorujacego — ubic i uruchomic
   ponownie (sam check jest read-only);
2. zatkana lokalna kolejka poczty — `postfix flush`, nigdy edycja ani porzucenie
   tresci wiadomosci;
3. nieudany NIEDESTRUKCYJNY check wygladajacy na chwilowy blip SSH/sieci —
   jedno powtorzenie, bez zmiany stanu;
4. przestarzaly `/var/run/*.lock` bez zywego wlasciciela — usuniecie, zeby
   nastepny cron nie zostal pominiety.

**Wszystko inne to raport, nigdy automatyczna naprawa** — w szczegolnosci:
zajetosc puli powyzej progu 90%, pula DEGRADED/FAULTED, `pvesr` FailCount > 0
lub opoznienie ponad kadencje zadania, nieosiagalny host, zablokowany token
resume/receive, jakakolwiek decyzja `zfs destroy`/hold/prune oraz dryf tresci
crontaba wobec bloku zarzadzanego.

Jesli taka rutyna kiedykolwiek powstanie, to jest jej punkt wyjscia — a decyzja,
czym ma byc, wraca wtedy do wlasciciela i recenzenta, a nie do implementera.

---

## ROZSTRZYGNIETE 2026-08-09 — decyzja #32, aktywny program prac

**Wlasciciel zatwierdzil program prac laczacy dwa kryteria: waznosc i koszt wdrozenia.**

Kanoniczna kolejnosc od tej decyzji jest zapisana w:

`docs/project/ACTIVE-WORK-PLAN.md`

Ten plik jest teraz aktywnym planem wykonawczym i ma pierwszenstwo przed
kolejnoscia z `PLAN-2026-08-07.md`, gdy dokumenty sie roznia. Stary plan
pozostaje historia decyzji i metoda pracy, nie drugim aktywnym backlogiem.

Kolejnosc wysokiego poziomu:

```text
V3 live gate
 -> CREATE-only additive
 -> endpoint/reactivation preserves policy
 -> --profile at CREATE + preview
 -> simple --source/--target workflow
 -> minimal presets + expert docs
 -> RESTORE
 -> optional conveniences only when backed by a concrete need
```

Obowiazuje redukcja zamiast kompletnego modelowania wszystkich wyjatkow:
preset tworzy nowy fragment, CONFIG v4 jest prawda po instalacji, a bespoke
policy pozostaje wspierane przez native CONFIG + dokumentacje zamiast przez
profile inheritance/drift/precedence framework.

---

## ROZSTRZYGNIĘTE 2026-08-14 — transakcyjna publikacja i ochrona `main`

**Decyzja Ownera:** „Zróbcie to.”

Owner zatwierdza oba uzgodnione elementy:

1. natychmiastową implementację transportowo niezależnego, transakcyjnego rdzenia
   `reviewctl approve` / `reviewctl close`, zgodnie z konsensusem
   `docs/discussions/PROTOCOL-TRANSACTIONAL-PUBLICATION-2026-08-14-CONSENSUS.md`;
2. GitHub branch protection dla `main`, z wymaganym istniejącym checkiem
   graph/protocol przed scaleniem.

Tym samym tymczasowy wyjątek direct-main z `docs/AI_PROJECT_RULES.md` zostaje
odwołany. Przejście jest skuteczne od publikacji towarzyszącej zmiany reguł; commity
zapisujące tę decyzję, powiadomienie ról i samą zmianę reguł są ostatnią
autoryzowaną migracją direct-main.

Po przejściu:

- implementacje, review i zmiany protokołu trafiają przez krótkie gałęzie i PR-y;
- `main` przesuwa się dopiero po wymaganej weryfikacji;
- nikt nie obchodzi ochrony administracyjnym bypass-em w zwykłej pracy;
- techniczna konfiguracja branch protection ma zostać wykonana przy najbliższej
  dostępnej zalogowanej sesji GitHub; do tego czasu reguła proceduralna obowiązuje,
  choć GitHub nie wymusza jej jeszcze serwerowo;
- brak aktywnej ochrony jest stanem przejściowym, nie przywróceniem wyjątku.

Nie zmienia to zakresu produktu ani Restore CLI. Rdzeń protokołu i finalny pass
Restore mogą postępować równolegle.

## ROZSTRZYGNIĘTE 2026-09-01 — emisja `-X/-e/-E` zostaje w `flags`; część wsadowa zamknięta

Pytanie implementera: po rozbiciu worka `flags` na nazwane pola
(`passive`, `exclude_family`, `exclude_child_<n>`) — czy przełączyć
`zfs-backup.sh`, żeby EMITOWAŁ te pola zamiast pakować `-X/-e/-E` do `flags`?

**Decyzja: NIE.** Rekomendacja implementera przyjęta bez zmian.

Powód, spisany, żeby nie wracał jako „luka do domknięcia":

- funkcjonalnie nie daje **nic** — gramatyka CONFIG v4 przyjmuje oba zapisy,
  a `gen-cron.sh` renderuje z nich tę samą linię silnika, co do bajta
  i w tej samej kolejności (asercja w `test/scopefields`);
- kosztuje **różnicę w crontabie na całej estacie**: przepisałby sekcję
  każdej istniejącej relacji przy jej najbliższej reaktywacji;
- wartość nazwanych pól jest w tym, że **wyższa warstwa może o nich mówić**
  (profil przez `[template:]`), a to działa już teraz, bez ruszania niczego,
  co jest zainstalowane.

Stare configi z `-X/-e/-E` wpisanymi ręcznie w `flags` są i zostają poprawne.
Odmowa „jedna opcja, jeden dom" pilnuje tylko tego, żeby ta sama opcja nie
przyszła z obu miejsc naraz.

**Konsekwencja dla planu: część wsadowa projektu jest zamknięta.** Etap profili
nie ma dalszych kroków — pasmo siedzi w manifeście parowania, rodziny
zarezerwowane przychodzą z profilu, `default` jest jawnym parametrem, a oś
zakresu ma nazwane pola z warstwą polityki. Kolejny etap jest po stronie GUI,
nie wsadu.

## ROZSTRZYGNIĘTE 2026-09-01 — żadnej bramki na „snapshoty bez retencji"

W odpowiedzi na REV-20260901-132 implementer nazwał resztkowe ryzyko: profil bez
własnego fragmentu `[prune]`, którego tiery też nie mają `prune_schedule`,
wyrenderuje zadania tworzące snapshoty i **nie** planujące żadnego cięcia.
Zaproponował bramkę na kandydacie — odmowę instalacji planu, który tworzy
snapshoty i nie tnie nic.

**Decyzja: NIE budujemy tego.**

Powód właściciela: *„Admin wie co robi. Być może prune załatwia inny skrypt,
albo mechanizm np. pvesr."* Konfiguracja, w której retencję prowadzi coś spoza
tego pakietu, jest legalna i spotykana — `pvesr` na Proxmoksie robi dokładnie
to na własnych rodzinach. Bramka odmawiałaby wtedy poprawnego wdrożenia,
a jedyną odpowiedzią operatora byłoby jej obejście.

To jest ta sama linia, co reszta narzędzia: **to jest narzędzie administratora,
nie ma barierek.** Odmowy zostają tam, gdzie chronią przed cichym zniszczeniem
CUDZYCH danych (rodziny zarezerwowane, strażnik antykasacyjny crona, odmowa
nakładania się pokrycia) — nie tam, gdzie odgadują intencję.

Konsekwencja dla `docs/internal/reviews/responses/REV-20260901-132.md`: sekcja
„Remaining risk" zapowiada tę zmianę jako osobną. Zapowiedź jest nieaktualna —
ryzyko zostaje nazwane i zaakceptowane, nie zamknięte.

## 2026-09-02 — `+` w etykietach crona zostaje; datasety wypisywane RAZ

Przy przebudowie digestu (`alert-digest.sh` v10→v13) właściciel czytał kolejne
wersje maila na prawdziwych hostach i podjął dwie decyzje.

**1. Znaku `+` w `gen-cron.sh` NIE ruszamy.**

`gen-cron` scala kilka datasetów w jedną linię crona, gdy mają identyczny
(harmonogram, cel, przedrostek, flagi), i łączy ich słowa `notify` znakiem `+`
(`IFS=+`, `gen-cron.sh:3263`). W mailu wyglądało to jak
`vm-103-disk-0+vm-104-disk-1+vm-107-disk-0+…`.

Właściciel chciał przecinków — ale **w wyświetlaniu, nie u źródła**:
*„plusy w gen-cron nie ruszamy"*.

Powód jest ten sam, co przy decyzji o emisji `-X/-e/-E` z 2026-09-01: zmiana
łączenia przepisałaby etykietę w **każdej** wygenerowanej linii crona. Crontab
każdego hosta różniłby się przy najbliższej regeneracji, a strażnik
anty-kasujący zobaczyłby stare linie jako usunięte. Koszt na całej estacie,
zysk czysto kosmetyczny.

Digest zamienia `+` na `,` przy wypisywaniu. **Konsekwencja przyjęta:** `+`
nadal widać w powiadomieniach o błędach (`notify-fail.sh`) i w `cron.log`,
bo tam etykieta jest tą samą, którą niesie linia crona. To nie jest luka.

**2. Datasety wypisywane w JEDNYM miejscu — w bloku stanu.**

Pierwsza wersja pokazywała je i w bloku stanu, i w tabeli przebiegów. Zmierzone
na pve0: mail 149 linii, z czego około 50 to duplikat. Po ograniczeniu do bloku
stanu — 104 linie. Decyzja właściciela: *„Zostaw jak jest"*.

Blok stanu odpowiada na pytanie „co to za host i co obejmuje", tabela przebiegów
na „jak chodziło"; nazwa zadania wystarczy, żeby je złączyć.

**3. Naglowek tabeli przebiegow podaje ZMIERZONE okno, nie nazwe okresu.**

Wlasciciel: *"Co to znaczy PRZEBIEGI ZADAN (2026-09-01, 2026-09-02)? Od do?"*
Dwie daty po przecinku nie mowia ani "od-do", ani nic innego — i **kryly realna
asymetrie**: digest chodzi o 07:00, wiec "dzisiaj" jest niepelna doba, a liczba
34 dla zadania godzinowego to 24 z wczoraj plus 10 z dzis.

Naglowek podaje teraz pierwszy i ostatni FAKTYCZNIE policzony przebieg
(`PRZEBIEGI ZADAN, 2026-09-01 00:01 - 2026-09-02 10:21`). Okno jest wtedy
pomiarem, a nie deklaracja, i arytmetyka tlumaczy sie sama.

**4. Okno tabeli przebiegow: 7 dni domyslnie, `ZFS_DIGEST_DAYS` do zmiany.**

Wlasciciel: *"A ten okres od-do to jakie ma okno czasowe? Definiowalne? Czy
zalozyles 1 tydzien/miesiac?"* — i odpowiedz brzmiala: **dwie doby, zahardkodowane,
nigdzie niepowiedziane**. Decyzja: *"7 dni domyslnie, ale konfigurowalne
parametrem"*. Codzienny mail pokazuje wiec tydzien trendu.

To otwiera tez raport tygodniowy, o ktory pytal wczesniej: cotygodniowy puls
(`cisza, kanal sprawny`) moze niesc statystyki z siedmiu dni bez nowej maszynerii.

**Przy okazji naprawione czytanie logow rotowanych — to nie byla kosmetyka.**
Logrotate chodzi MIESIECZNIE (`rotate 24`, `compress`, `delaycompress`), a digest
czytal wylacznie zywy `cron.log`. Konsekwencja: **pierwszego dnia miesiaca
wszystkie liczby bylyby zanizone bez slowa ostrzezenia**, bo okno trafialoby w
log urwany poprzedniego dnia. Zmierzone na pve0 2026-09-02: `cron.log` zaczynal
sie 09-01, a dwadziescia megabajtow sierpnia lezalo w `cron.log.1`.

Pliki rotowane sa teraz dobierane po czasie modyfikacji (plik zapisany przed
poczatkiem okna nie moze zawierac przebiegu z tego okna, i stwierdzenie tego nie
kosztuje dekompresji) i czytane przez `zcat -f`, ktory bierze i zwykle, i `.gz`.

Dowod liczbowy: 35 przebiegow przy oknie 2 dni, **155 przy 7**; najdluzszy czas
7 s kontra 120 s — ta ostatnia wartosc to realny sierpniowy przypadek, ktorego
wczesniejsze okno nie widzialo wcale.
