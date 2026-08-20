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

## O8. `--pause` i `--resume` robią najpierw pełne wdrożenie — DO DECYZJI

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

Skłaniam się do (1) — (2) leczy objaw.

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

## O12. `snapget` opisuje odmowę bramy jako „brak zfs w PATH" — DO DECYZJI

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
to. Ale `snapget.sh` jest **zamrożony** (ENGINE-FREEZE), więc to decyzja
właściciela, nie moja. Dotyczy tak samo `snapsend.sh`.

**Nie naprawiam samodzielnie.**
