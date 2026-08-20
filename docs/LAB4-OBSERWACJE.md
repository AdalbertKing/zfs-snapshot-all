# LAB4 — obserwacje z wdrożenia i proponowane poprawki

Rejestr narastający. Jedna pozycja = jedna obserwacja z **prawdziwego**
przebiegu na metropolis, z propozycją (albo świadomą jej odmową).

Konwencja statusu: **NAPRAWIONE** / **DO DECYZJI** / **ODRZUCONE** / **OBSERWACJA**.

---

## O1. `cron_lock_files_repair` nigdy nie działał — NAPRAWIONE (PR #71)

Definicja w gałęzi `--check-only`, wywołanie w gałęzi `else`. Przy każdym
prawdziwym wdrożeniu `command not found`, skrypt leciał dalej. Commit `2f69c2d`
z 7 sierpnia — trzynaście dni.

Kosztowało: to jest naprawa pliku blokady `0644`, który zamyka konto delegowane
przed jego własnym crontabem — zmierzone na **trzech z czterech** hostów
produkcyjnych 2026-08-07.

Żadna suita nie mogła tego złapać: suity wyciągają funkcje `sed`-em i wołają
je, więc definicja u nich zawsze istnieje. Widać to **wyłącznie** z prawdziwego
przebiegu.

Poprawka: obie funkcje przeniesione na poziom pliku. Sprawdzone funkcjonalnie —
podłożony zamek `0644 root:root` wyszedł z deploya jako `0664 root:zfsalert`.

## O2. Wznowienie nazywało zły brakujący krok — NAPRAWIONE (PR #71)

Ze stanu `pending_enroll` ponowienie tej samej komendy **nie ponawia joinu**
(log wznowienia: 2 linie, 0 prób) i wywalało się na pobraniu zakresu pytaniem
„czy `--draft-scope` już tam chodził?". Operator szedł sprawdzać szkic na hoście,
który nigdy nie przyjął wsadu.

Poprawka: manifest peera rozstrzyga — jego brak znaczy join, obecność znaczy
szkic. Oba komunikaty mówią teraz który, a ten o joinie mówi wprost, że
ponowienie go nie ponowi.

**Świadomie niezrobione:** faktyczne ponawianie joinu. `cmd_add_client` odmawia
istniejącemu klientowi, więc to przepisanie ścieżki parowania, nie poprawka
komunikatu.

## O3. Stan `removed` raportowany jako „unknown" — NAPRAWIONE (PR #71)

Wpadał w gałąź domyślną i odsyłał do `status/seed/activate`, z których żaden nie
odnawia usuniętej relacji — a nic innego w drzewie też nie. Ma własny przypadek
mówiący, że jest terminalny, i wskazujący `--name=NOWA`.

## O4. Prefiks seeda — ODRZUCONE (moja pomyłka)

Zgłosiłem `-m automated_daily_` w seedzie jako niespójność z monitorem pilnującym
`automated_hourly`. **Odwrotnie.** Seed nazwany godzinowo byłby świeżym
**pasującym** snapshotem niezależnie od tego, czy godzinowy job kiedykolwiek
ruszy — czyli najnowsze, co widziałby monitor, byłoby artefaktem enrolmentu, nie
dowodem harmonogramu. Drabinka GFS kasuje po `automated_`, więc seed i tak
podlega retencji. Udokumentowane w miejscu wywołania.

## O5. `--grant-remotely` był niewidoczny — NAPRAWIONE (PR #72)

Przemiał przełączników objął `deploy.sh` i `gen-cron.sh`, **pominął
`zfs-backup.sh`**. Dwie działające flagi bez wpisu w pomocy, w tym ta skracająca
enrolment z **czterech komend do jednej**.

Zmierzone na żywo: jedna komenda, zero → `STATE=active`, md5 zgodne. Własności
dotrzymane: zakres z linii poleceń (`1 dataset(s) granted, 0 revoked, 0 held
back`), audyt na źródle, zwykła weryfikacja po fakcie.

**Cztery poprawki z laba nie skróciły niczego** — redukcja siedziała przez cały
czas w niewidocznej fladze.

## O6. Rozjazd stref czasowych widoczny tylko ze źródła — DO DECYZJI

Nazwę snapshotu nadaje kolektor, `creation` zapisuje źródło. Przy różnych
strefach rozjeżdżają się — i **z kolektora tego nie widać**, bo tam obie
wartości są w tej samej strefie.

Zmierzone: pve9 `+0000`, kolektory `+0200`.

```
na pve1:  automated_hourly_..._17-01-01   creation 17:01   <- wyglada dobrze
na pve9:  automated_hourly_..._17-01-01   creation 15:01   <- rozjazd 2h
```

`zfs-backup.sh` ostrzega o tym **przy enrolmencie** i to zadziałało. Monitor jest
odporny (czyta `creation`), ale `restore --plan` zgłosi rozjazd.

Propozycja, do decyzji właściciela:
1. **Nic w kodzie**, wyrównać `timedatectl` na pve9 — ostrzeżenie było trafne
   i wystarczające. Najprostsze.
2. Dołożyć tę samą kontrolę do `status`, bo dziś sprawdza się ją **raz**, przy
   zapisie relacji; zmiana strefy na hoście po fakcie nie jest przez nic łapana.

Skłaniam się do (1) plus (2) jako drobnego dodatku — kontrola już istnieje,
chodzi tylko o drugie miejsce wywołania.

## O7. Harmonogram działa — OBSERWACJA

Po trzech cyklach: snapshoty o **15:01, 16:01, 17:01**, równo co godzinę, na obu
kolektorach. Monitory `rc=0` dla wszystkich trzech relacji. Markery `ZFS-JOB`
parami BEGIN/END, 14 wpisów w logu.

To jest to, czego jednorazowy przebieg nie dowodzi: że **harmonogram** działa,
a nie tylko że transfer się udał.

---

# Testy trzech pauz (2026-08-20)

Trzy niezależne mechanizmy, sprawdzone po kolei na żywo. Wszystkie trzy
**działają**; poniżej to, co przy okazji wyszło.

| mechanizm | komenda | co rusza |
|---|---|---|
| pauza zadania | `deploy.sh --pause` / `--resume` | crontab hosta (root **i** konto) |
| miękka pauza relacji | `zfs-backup.sh pause-client` | plik stanu, brama `-L` w runtime |
| twarda pauza relacji | `zfs-backup.sh disable-client` | marker u **peera**, blokuje też bez `-L` |

Wynik pomiaru pauzy zadania na pve9 — wszystkie własności z helpa dotrzymane:
ciało bloku zakomentowane a markery zostają, ponowna pauza odmawia (rc=1),
ręczna linia dopisana w oknie **przetrwała i została zgłoszona**, crontab konta
wrócił bajt w bajt.

## O8. `--pause` i `--resume` robią najpierw pełne wdrożenie — NAPRAWIONE (droga 1)

Gałąź pauzy leży w `deploy.sh` **za** fazami. Zmierzone: `--pause` przeleciał
9 faz (`Phase 1 2 4 4a 4b 5 6 6a 7`), dopiero potem zapauzował. To nie jest
teoria z czytania kodu — to lista faz z logu prawdziwego przebiegu.

Skutek widać przy `--resume`, gdzie faza 7 i 5 próbują pisać do bloku, który
jeszcze jest zapauzowany:

```
45:!!! could not install the auto-update cron line: this block is currently
     paused -- ... -- this host would stop picking up updates
52:!!! could not install the capacity-check cron line: ...
59:>>> root/zfs-backup-host: staged for resume        <- dopiero TERAZ wznawia
```

Linia 45 straszy utratą aktualizacji, a osiem linii niżej wszystko jest w
porządku. Blokada zadziałała poprawnie (fail-safe), ale **alarm jest fałszywy**
— i to jest ten rodzaj `!!!`, który uczy operatora ignorować `!!!`.

Dwie drogi, do decyzji właściciela:

1. Przenieść wysyłkę `--pause`/`--resume` **przed** fazy. Czysto koncepcyjnie
   poprawne — pauza to operacja wyłącznie na crontabie, nie ma powodu ciągnąć
   repo, przepisywać `notify-fail.sh` ani instalować linii crona. Kosztuje
   przeniesienie całej rodziny funkcji `do_pause*`/`do_resume*`/`pause_targets`
   ponad fazy, bo bash nie zna funkcji zdefiniowanej niżej.
2. Tanio: w trybie pauzy/wznowienia zdegradować te dwa `!!!` do zwykłego
   komunikatu z wyjaśnieniem. Usuwa fałszywy alarm, zostawia dziwność, że
   „pauza" robi wdrożenie.

Właściciel wybrał (1). Cała rodzina `do_pause*`/`do_resume*`/`pause_targets`
przeniesiona ponad fazy razem z wysyłką — bash nie zna funkcji zdefiniowanej
niżej, więc samo przesunięcie `if`-a nie wystarczało. Przed przeniesieniem
sprawdzone, że blok jest samowystarczalny: woła wyłącznie `log`/`warn`
(linie 153–154) i `lib-cron.sh` (sourcowane w linii 103), a `detect_delegated_account`
i `cron_block_names_present` są używane tylko wewnątrz niego.

Zmierzone na żywo na pve9, z worktree na gałęzi (checkout główny nietknięty
na `main`):

| | przed | po |
|---|---|---|
| `--pause`, linii logu | 61 | **4** |
| `--pause`, faz wdrożenia | 9 | **0** |
| `--resume`, fałszywych `!!!` | 2 | **0** |
| crontaby po cyklu | — | identyczne bajt w bajt |

**Suita złapała to przeniesienie — ale przez awarię, nie przez raport.**
`test/pause` kończyła wycinanie kodu na `# do_revoke_old`, czyli na komentarzu,
który *przypadkiem* stał zaraz za rodziną funkcji. Gdy sąsiedztwo zniknęło,
`sed` wciągnął resztę pliku razem z wysyłką i suita wywaliła się na
`PAUSE_MODE: unbound variable` — daleko od przyczyny. `deploy.sh` ma teraz jawny
terminator, a suita odmawia wprost, jeśli wycinanie kiedykolwiek znów sięgnie
wysyłki. Kontrola pozytywna: po skasowaniu terminatora suita pada z tym nowym
komunikatem, nie ze starym.

## O9. Miękka pauza **nie pauzuje retencji** — NAPRAWIONE (komunikat)

`pause-client` mówi: *„Managed jobs and labeled manual runs now exit SKIPPED"*.
Dla linii transferu i monitora to prawda. Dla retencji nie.

Relacja `lab4-direct` ma **cztery** linie crona, ale `-L` jest tylko na dwóch:

```
snapget          -L lab4-direct     <- bramkowane
check-snap-age   -L lab4-direct     <- bramkowane
delsnaps (cel)   brak -L            <- CHODZI DALEJ
delsnaps (zrodlo) brak -L           <- CHODZI DALEJ
```

To nie jest przeoczenie generatora: `delsnaps.sh` **nie zna** flagi `-L`
(`grep -c '\-L' delsnaps.sh` = 0, usage jej nie wymienia), a `gen-cron.sh:103`
mówi wprost „Becomes -L on the transfer line".

Zmierzone przy zapauzowanej relacji — prune **źródła** przeszedł normalnie:

```
./delsnaps.sh -n -G ... "zfsbackup-pve1@192.168.28.99:hdd/lab4/src2" ...
[DRY-RUN] Would keep snapshot: hdd/lab4/src2@automated_hourly_... (GFS H#1)
rc=0
```

Skala szkody: **ograniczona**, bo drabinka GFS trzyma H24/D7/W4/M12, więc
wspólna baza przeżyje pauzę liczoną w miesiącach. Ale kierunek jest niemiły —
przy zatrzymanej replikacji nadal chodzi **kasująca** retencja po cudzym
źródle.

Poprawka: komunikat `pause-client` i `status` mówią teraz, czego pauza **nie**
obejmuje. Kod retencji nietknięty — bramkowanie `delsnaps` to zmiana
zamrożonego silnika i osobna decyzja.

## O10. Twarda pauza była **niemożliwa**, a kod twierdził coś odwrotnego — NAPRAWIONE

`disable-client lab4-direct` padł:

```
!!! the peer did NOT confirm the disable (ssh/gate said: zfs-pair-gate: line 231:
    /var/lib/zfs-snapshot-all/relationships/pve1/disabled.new: Permission denied)
FATAL: retry the same command once the peer is reachable -- it is a safe retry
```

Obsługa błędu jest wzorowa: mówi dokładnie co jest zrobione (pauza lokalna),
czego nie ma (blokady u peera), i że retry jest bezpieczny. Ale przyczyna to
defekt wdrożenia.

Przyczyna, udowodniona z kontrolą pozytywną na pve9:

```
zfsbackup-pve1  groups=1003(zfsbackup-pve1)          <- BEZ zfsalert
katalog:        2775 root:zfsalert relationships/pve1
touch jako zfsbackup-pve1  -> Permission denied  rc=1
touch jako zfsbackup       -> rc=0               <- kontrola pozytywna
```

Katalog odziedziczył grupę `zfsalert` przez bit setgid rodzica, zamiast dostać
grupę konta. `deploy.sh:4121` robi `chown root:$account`, ale to `|| :` — a więc
gdy nie zadziała, zostaje tylko ostrzeżenie.

**I tu jest właściwe znalezisko.** Kontrola `gate_state_dir_ok` wykrywa ten stan
poprawnie, ale komentarz i komunikat opisują **złą konsekwencję**:

> `deploy.sh:4138` — *„disable still WORKS and is enforced, but 'enable' through
> the gate will refuse"*

Zmierzone: poległ **disable**. `disable` tworzy plik w tym katalogu, `enable`
kasuje plik w tym katalogu — oba są zapisem **do katalogu** i oba wymagają
prawa zapisu. Na tym błędnym przekonaniu opiera się decyzja „not fatal to the
join, deliberately", więc enrolment kończy się wyglądając na kompletny, a
twardej bramy nie da się w ogóle założyć. Komentarz mówi, że ten sam objaw
widziano na metropolis pve2 w 2026-08-06 — czyli powtórzył się, był ostrzegany,
a ostrzeżenie zaniżało wagę.

Naprawione na żywo (`chown root:zfsbackup-<peer>` + `chmod 0775` na obu
katalogach pve9) — po tym `disable-client` przeszedł od razu, co domyka dowód
przyczyny. W kodzie: komunikat mówi teraz prawdziwą konsekwencję.

## O11. `status` nie pokazuje twardej pauzy — NAPRAWIONE

Przy relacji zablokowanej u peera `status` pokazywał wyłącznie:

```
Pauza: PAUSED_LOCAL od 2026-08-20 17:32:01
       ... reczne uruchomienie BEZ etykiety NIE jest blokowane
```

To zdanie było wtedy **nieprawdziwe**. Dowód — ręczny `snapget` bez `-L`:

```
PAIR_DISABLED: relationship pve1 is disabled by administrator
rc=1
```

Operator czytający `status` widział miękką pauzę i zdanie zapewniające, że
granicy bezpieczeństwa nie ma, podczas gdy peer odmawiał wszystkiego.

Poprawka: `status` odpytuje bramę i raportuje stan u peera osobno od pauzy
lokalnej; zdanie o nieblokowanych komendach pojawia się **tylko** wtedy, gdy
jest prawdziwe.

## O13. Rozbiórka: co zostawiają narzędzia — ZMIERZONE

Skryptu „usuń pakiet i wszystkie ślady z hosta" **nie ma** — to zaplanowana
pozycja `clean_all` (`docs/project/TODO-THREADS-2026-08-17.md`, punkt 4).
Istnieją dwa czasowniki cząstkowe i oba działają dobrze w swoim zakresie:

- `zfs-backup.sh remove-client NAME` — strona kolektora
- `deploy.sh --leave=<label>` — strona źródła

Rozebrałem nimi trzy relacje na trzech hostach, mierząc inwentarz przed i po
każdym wywołaniu. **Produkcja nietknięta** na obu kolektorach — md5 crontaba
konta `zfsbackup` identyczne przed i po całej rozbiórce.

`remove-client` **usuwa**: linie crona relacji, `peers/<ip>.conf`, trzy z
czterech plików klucza, `pairing/<ip>.conf.suggested`, `pairing/<host>-to-<ip>.tgz`.

`--leave` **usuwa**: granty ZFS, konto **razem z katalogiem domowym**, manifest
joinu, plik scope i jego sumę.

Co zostaje po obu, zmierzone (to jest specyfikacja dla `clean_all`):

| ślad | gdzie | uwaga |
|---|---|---|
| `clients/<name>.conf` ze `STATE=removed` | kolektor i źródło | z projektu — log stanu jest dopisywalny; ale stan jest **terminalny**, więc blokuje ponowne użycie nazwy |
| `relationships/<label>/` | oba | znana luka, potwierdzona ponownie |
| `peers/<label>.conf` + `.scope` + `.scope.sha256` | kolektor | **nowe**: `peers/` jest kluczowane **dwojako** — po IP i po etykiecie; `remove-client` usuwa tylko wariant po IP |
| `<addr>_alias_known_hosts` | kolektor | **nowe**: jedyny z czterech plików klucza, który przeżywa — i akurat ten, którego używały linie crona (`-k ..._alias_known_hosts`) |

Osobno, zastane po starszych testach na pve2: trzy katalogi `/home/zfsbackup-*`
**bez kont** (`id` odmawia dla wszystkich trzech), z czego dwa należały do
**żywego** konta `zfsbackup-pve1`, które przejęło ich UID. Zawartość to same
dotfile'y, więc bezpieczeństwo nietknięte — ale „kasuj to, co należy do tego
konta" jako strategia właśnie umarła. To drugi, niezależny powód dla reguły
*whitelist, nigdy sweep*.

Omal nie zaraportowałem tych trzech jako żywych kont z dostępem. Puste pole
powłoki z `getent passwd` **nie jest** dowodem na istnienie konta; `id` jest.

## O14. `--grant-remotely` wiesza się na parze hostów, która NIE jest sparowana — NAPRAWIONE (obie drogi)

Przy wdrożeniu od zera, na **sterylnych** hostach, jedna komenda stanęła i stała
przez ponad sześć minut bez żadnego komunikatu. Zmierzone, nie wywnioskowane:

```
pve2:  bash zfs-backup.sh --source=... --grant-remotely --install --yes   (05:48)
pve2:   \_ ssh root@192.168.28.99 ... ./deploy.sh --join=/root/pve2-to-...tgz  (05:44)
pve9:      \_ /bin/bash ./deploy.sh --join=...   wchan=pipe_read  stdin=pipe:[188378]
```

`deploy.sh --join` **pyta o akceptację zakresu i celowo nie ma `--yes`** — to
jest udokumentowana decyzja bezpieczeństwa (§4 runbooka). Uruchomiony przez ssh
bez terminala nie ma jak dostać odpowiedzi i **nie ma żadnego limitu czasu**.

Sedno jest w tym, że wołający **już** to toleruje. `zfs-backup.sh:3357` mówi
wprost: „whether `--join-remotely` succeeded … or fell back to manual
instructions" — nieudany join nie jest śmiertelny i jest przewidziany awaryjny
tor ręczny. Ten tor **nigdy się nie włącza**, bo wywołanie nie wraca.

> Projekt, który znosi porażkę, jest pokonany przez wywołanie, które nie potrafi
> się nie udać.

Dowód po fakcie: po zakończeniu zdalnego procesu wołający natychmiast poszedł
swoim torem awaryjnym i **enrolment dokończył się poprawnie** — grant zatwierdzony
na źródle (`hdd/lab4/src -> user zfsbackup-pve2`), scope na miejscu, dane
przesłane, cron zainstalowany, `STATE=active`. Czyli to nie jest fail-open:
brakowało wyłącznie ograniczenia czasu na krok, który z definicji nie może
odpowiedzieć.

**Korekta mojego wcześniejszego raportu (O5).** Napisałem, że `--grant-remotely`
przeszło „od zera do `STATE=active`" i że to „pierwsze uruchomienie tej ścieżki
na żywo". Flaga faktycznie zadziałała, ale para hostów pve1↔pve9 **była już
sparowana** wcześniej tego dnia, więc `--join` nie był potrzebny i krok, który
teraz się wiesza, wtedy się nie wykonał. „Od zera" było nieprawdą i to jest
pierwszy przebieg na naprawdę niesparowanej parze.

Kierunki poprawki (do decyzji właściciela — dotyka granicy bezpieczeństwa):

1. **Nie wieszać się nigdy.** Zdalny `--join` dostaje limit czasu i zamknięte
   wejście; po przekroczeniu wołający robi to, co i tak umie — wypisuje ręczne
   instrukcje. Sama ta zmiana usuwa awarię i nie rusza granicy bezpieczeństwa.
2. **Wykryć wcześniej.** `--grant-remotely` sprawdza *przed* startem, czy para
   jest już sparowana, i jeśli nie — odmawia od razu, zamiast zaczynać pracę,
   której nie dokończy.
3. Rozszerzyć jawną, audytowaną zgodę `--grant-remotely` na przyjęcie zakresu.
   To realna zmiana granicy bezpieczeństwa; nie proponuję jej samodzielnie.

Skłaniam się do (1) **plus** (2): pierwsze usuwa zawieszenie, drugie sprawia, że
komenda mówi prawdę o swoim zakresie stosowalności, zanim cokolwiek zrobi.

**Poprawka (1) została zmierzona, nie tylko wyrozumowana.** Drugi skok
uruchomiłem z zamkniętym wejściem (`</dev/null`) i własnym limitem czasu.
Zdalny `--join` dostał EOF zamiast czekać w nieskończoność i **istniejący tor
awaryjny włączył się dokładnie tak, jak zaprojektowano**:

```
FATAL: join interrupted before scope acceptance
!!! --join-remotely could not complete automatically -- falling back to the
    manual steps below.
>>> Wsad gotowy: /root/scripts/pairing/pve1-to-192.168.28.8.tgz
```

Czyli kod na to zawieszenie **już ma odpowiedź** — brakuje wyłącznie tego, żeby
ją mógł osiągnąć. To najtańsza możliwa poprawka: ograniczyć czas i zamknąć
wejście, nic więcej.

### Zrobione — obie drogi (decyzja właściciela)

**Droga 1 — nigdy się nie wieszać.** `deploy.sh` woła teraz zdalny join jako
`timeout "$PEER_REMOTE_JOIN_TIMEOUT" ssh -n ...`, i to `-n` jest tu istotne:
zdalny odczyt dostaje EOF natychmiast, `--join` kończy się swoim własnym
„join interrupted before scope acceptance", czyli **dokładnie tą porażką, dla
której gałąź `else` została napisana**. `timeout` (300 s) jest drugim
ograniczeniem, na zator niezwiązany ze standardowym wejściem. Jego własny brak
też jest bezpieczny, nie sprytny: bez `timeout` polecenie po prostu się nie uda
i wpadnie w tę samą gałąź `else` zamiast wisieć. Zator (`124`) jest nazywany
osobno od odmowy — inaczej operator szuka komunikatu ssh, którego nigdy nie było.

**Droga 2 — pytać wcześniej.** Nowe `rux_grant_remotely_preflight` sprawdza kanał
root-ssh **i** obecność manifestu joinu na źródle, zanim powstanie cokolwiek:
konto, rekord klienta, klucze, wsad. Bez joinu nie ma konta, do którego grant
miałby trafić, więc flaga nie może dotrzymać swojej obietnicy „jedna komenda
zamiast czterech" — a dowiadywanie się o tym w połowie zostawiało niedokończonego
klienta do sprzątnięcia. Odmowa wypisuje pełną drogę dwustronną i mówi wprost,
że przy **kolejnej** relacji z tym hostem flaga znów zadziała.

Przy okazji naprawiona druga sztuka tej samej choroby: komentarz nad
`rux_grant_remotely` obiecywał *„no root channel → refuse EARLY, before any state
changes"*, a funkcja była wołana **po** `cmd_add_client`. Obietnica dotyczyła
komunikatu, nie umiejscowienia.

Testy regresyjne: `joinremote` 8 i 9, `rux` 25–28. Sprawdzone, że **padają na
kodzie sprzed poprawki** (2 i 4 błędy odpowiednio) i przechodzą po niej. `rux` 26
jest kontrolą pozytywną — ta sama bramka przepuszcza peera, który dołączył, bo
bramka, która nigdy nie otwiera, niczego nie dowodzi.

## O16. Obie drogi z O14 dowiedzione na żywo — ZMIERZONE

Na parze **naprawdę niesparowanej** (pve1↔pve9; `lab4-direct` rozebrane
i nieodbudowane, pve1 bez kluczy do `.99`, pve9 bez manifestu `pve1`).

**Droga 2** — `--grant-remotely` na tej parze:

```
rc=1   czas=1s
FATAL: --grant-remotely: 192.168.28.99 has not joined 'pve1' yet ...
       Nothing was changed anywhere -- no client record, no keys, no package.
```

Jedna sekunda zamiast sześciu minut. I sprawdzone, że zdanie „Nothing was
changed anywhere" jest **prawdziwe**, a nie tylko napisane: `clients`, klucze,
`pairing`, `peers`, crontab i md5 produkcji identyczne po obu stronach.

**Droga 1** — ten sam enrolment bez tej flagi, gdzie join **jest** podejmowany:

```
rc=1   calosc=11s
!!! --join-remotely could not complete automatically -- falling back to the
    manual steps below.
FATAL: join interrupted before scope acceptance
```

Jedenaście sekund i poprawne zatrzymanie na grancie, zamiast wiszenia bez końca.
Tor awaryjny włączył się sam, bez mojego `</dev/null` — czyli to, co wcześniej
wymuszałem ręcznie, robi teraz kod.

| | przed | po |
|---|---|---|
| `--grant-remotely`, para niesparowana | wisi bez końca | **1 s**, odmowa, zero zmian |
| zwykły enrolment, join podejmowany | wisi bez końca | **11 s**, tor awaryjny |

Uboczne, wartościowe: join zdążył utworzyć manifest, konto i szkic zakresu na
źródle **zanim** doszedł do pytania — więc „interrupted before scope acceptance"
zostawia stan użyteczny, a nie połowiczny śmieć.

## O17. Sam popsułem sobie rozbiórkę kolejnością — WNIOSEK

Dwie pomyłki własne, obie warte zapisania, bo obie są łatwe do powtórzenia.

**Kolejność.** Skasowałem `peers/pve9.conf` ręczną whitelistą, a dopiero potem
uruchomiłem `deploy.sh --leave=pve9`. Manifest jest mapą, z której `--leave`
czyta, co cofnąć — bez niego odmawia:

```
FATAL: no join manifest for 'pve9' ... -- nothing to leave
```

Odmowa jest poprawna, narzędzie nie zgaduje. Ale konto zostało wtedy **poza
zasięgiem narzędzia** i musiałem usunąć je ręcznie — czyli zrobić dokładnie to,
czego reguła whitelisty ma unikać. `--leave` idzie PRZED sprzątaniem ręcznym.

**Źródło listy.** Wyprowadziłem listę `--leave` z topologii łańcucha, który sam
budowałem, i przegapiłem konto `zfsbackup-pve9` na pve1 — pozostałość po
starszym labie, w którym pve1 było źródłem. Żywe konto, klucz i powłoka, przy
zerze grantów ZFS, zerze linii crona i zerze odwołań w konfiguracji; klucz
bramkowany przez `zfs-pair-gate pve9`, więc zasięg był ograniczony. Usunięte,
z zapisem `passwd` i klucza odłożonym na wypadek cofnięcia.

Pytanie do zadania brzmi **„jakie konta `zfsbackup-*` są na tym hoście i czym
każde jest uzasadnione"**, nie „jakie relacje ja budowałem". To trzeci powód dla
reguły whitelisty — obok recyklingu UID z O13.

## O15. Wdrożenie od zera bez błędów — OSIĄGNIĘTE

Po pełnej rozbiórce (O13) i na sterylnych hostach zbudowany cały łańcuch
`pve9 → pve2 → pve1`, celowo **tymi samymi nazwami co poprzednio** — gdyby
rozbiórka była niepełna, domyślna nazwa rozbiłaby się o terminalny stan
`removed`. Nie rozbiła się.

```
pve9  hdd/lab4/src              4024852c...  b5c0189a...   <- odniesienie
pve2  hdd/lab4backups/...       4024852c...  b5c0189a...   zgodne
pve1  hdd/lab4chain/...         4024852c...  b5c0189a...   zgodne
```

Drugi skok: `rc=0`, **zero linii `!!!` i zero `FATAL`**, `STATE=active`.

Produkcja nietknięta na obu kolektorach — crontab konta `zfsbackup`
identyczny bajt w bajt, zero grantów na `hdd/vm-disks`, `hdd/backups`,
`rpool/data`, `rpool/ROOT`, a granty labowe wyłącznie na własnym liściu.
Zadania rozdzielone tak jak mają być: lab w crontabie roota z
`jobs.<host>.conf`, produkcja na koncie z `jobs.<host>.v4.conf`.

Jedyne zatrzymanie po drodze było **poprawne**: grant jest decyzją strony
źródłowej, więc `--commit-scope=pve1` trzeba było wykonać na pve2. Przed
przyznaniem obejrzany szkic — dokładnie jedna sekcja `[dataset:]`, kopia
labowa, zero produkcji.

## O12. `snapget` opisuje odmowę bramy jako „brak zfs w PATH" — NAPRAWIONE

Ten sam przebieg co wyżej. Silnik dostał odpowiedź, która sama się nazywa:

```
PAIR_DISABLED: relationship pve1 is disabled by administrator
```

i zaraportował:

```
Pool 'hdd' on 192.168.28.99 is UNKNOWN
... existence check could not run (exit 93 -- e.g. no 'zfs' in this account's
PATH). Treating this as UNKNOWN, not as a missing dataset.
```

Odpowiedź była w ręku i została zgadnięta na inną. To ta sama klasa błędu, co
kiedyś z `exit 255` (konkretna awaria łącza opisywana jako problem z danymi):
**nie zgaduj, kiedy odpowiedź jest w treści**.

Poprawka jest tania — jeśli zebrane wyjście zawiera `PAIR_DISABLED:`, powiedz
to. Ale silnik jest **zamrożony** (ENGINE-FREEZE), więc to decyzja właściciela.

### Zrobione — po decyzji „Odblokuj silnik i napraw O12"

Kod siedział w `lib-zfs-snap.sh`, nie w samym `snapget.sh`, więc poprawka objęła
oba silniki naraz. Jeden wspólny rozpoznawacz `remote_refused_by_gate`: kod
wyjścia `93` (`RC_DISABLED` z `zfs-pair-gate.sh`) jest kontraktem, tekst
`PAIR_DISABLED:` potwierdzeniem — bo `remote_list` celowo nie przechwytuje
stderr peera i tam zostaje sam kod.

**Trzy miejsca, i trzecie okazało się najgroźniejsze.** `pool_health`
wyrzucało kod wyjścia do `/dev/null`, więc odmowa spadała na `UNKNOWN` —
a `check_pool_health` **wysyła mail na wszystko, co nie jest ONLINE**. Czyli
blokada administracyjna podnosiła **alarm o stanie magazynu** dla całkowicie
zdrowej puli. To nie jest mylący komunikat, to fałszywy alarm o dyskach:

```
Pool 'hdd' on 192.168.28.99 is UNKNOWN     <- pula byla zdrowa
```

Teraz zwraca `PAIR-DISABLED`, mówi wprost, że nie wolno było zapytać, i **nie
alarmuje** — instrumentem od „ta relacja przestała kopiować" jest
`check-snap-age`, w swoich własnych kategoriach.

**Znalezione przy okazji, bo pierwszy raz przetestowałem `pool_health` wprost.**
Obie funkcje z cache budowały klucz wewnątrz tego samego `local`, które
deklarowało ich wejścia. Bash rozwija te słowa **zanim** wbudowane `local` się
wykona, więc klucz powstawał z zakresu **zewnętrznego** — nieustawiony pod
`set -u`, a przy istniejącym zewnętrznym `pool` po cichu **z cudzą wartością**:

```
$ f(){ local a="$1" b="$a-x"; echo "$b"; };  a=OUTER; f Z
OUTER-x        <- nie "Z-x"
```

Działało wyłącznie przypadkiem: `check_pool_health` deklaruje własne
`local pool` tuż przed wywołaniem. Stawką jest klucz cache, więc zły klucz
przechodzi między pulami. Naprawione w `pool_health` i w bliźniaku
`csend_pool_has` — połowiczna naprawa błędu, który ma bliźniaka, to sposób na
utrwalenie bliźniaka.

Semantyka transferu nietknięta: każda zmiana to diagnoza, wartość zwrotna już
zarezerwowana dla „nie wiadomo", albo wyciszenie fałszywego alarmu.

Testy: `test/quiesce` +11, sprawdzone jako **padające na zamrożonej bazie**
(11 błędów), w tym kontrole, że nowy rozpoznawacz **nie** przemianowuje zwykłej
awarii zdalnej na blokadę administracyjną. Rozmrożenie zapisane w
`docs/project/ENGINE-FREEZE.md` — pierwszy wpis na tej liście, który był
**autoryzowany z góry**, a nie zgłoszony po fakcie.
