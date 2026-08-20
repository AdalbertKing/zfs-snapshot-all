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
