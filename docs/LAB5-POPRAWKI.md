# Wnioski z kampanii → lista poprawek

Osiem znalezisk z macierzy wdrożeń 2026-08-20 (`docs/LAB5-KAMPANIA.md`),
uporządkowanych jako praca. Kolejność: naprawione, potem otwarte według tego,
co kosztuje najwięcej, gdy zawiedzie.

P10 dopisane później i **spoza macierzy** — wyszło 2026-08-21 przy pytaniu
o `server.conf`. Trafiło tutaj, bo należy do tej samej rodziny co reszta.

## Wspólna diagnoza

Wszystkie osiem to jedna rodzina:

> **Fakt lokalny użyty jako dowód faktu zdalnego, albo argument użyty jako
> dowód zamiaru.**

Manifest, który dowodził tylko własnego istnienia. Zakres wyglądający na
żądanie, będący akumulacją. `--source`, który wygląda na wybór, a jest adresem
peera. Straż, która istnieje, ale nie tam, gdzie zapada decyzja.

To jest kryterium przeglądu na następną rundę: **przy każdym komunikacie i
każdej bramce zapytać, czy sprawdzana rzecz naprawdę dowodzi tego, co się
o niej twierdzi.**

---

## Zrobione

### P1. `gen-cron.sh --uninstall` — PR #85

Wdrożenie jednoserwerowe instalowało blok, którego nic nie potrafiło zdjąć.
Właściciel bloku umie go teraz usunąć. Bez `-c`, bo typowym powodem sięgnięcia
jest zniknięcie configu. Usuwa **harmonogram, nie kopie** i mówi to wprost.

### P2. `clean-relationships.sh` widzi klucze konta i osierocone adresy — PR #86

Relacja z `--local-user` używa `/home/<konto>/.ssh/pairing-<adres>_*` — prefiks,
gdzie root ma katalog. Narzędzie było ślepe w kształcie produkcyjnym. Osobno:
`SEEN_ADDR` zbierane i nigdy nieraportowane.

### P3. Rozróżnik „join czy draft" — PR #86

Testował plik, który kolektor pisze sam przy `--pair`. Gałąź nieosiągalna,
komunikat zawsze zły. **Miał dwa zielone testy** — piaskownica potrafiła
stworzyć stan, którego prawdziwy system nie produkuje.

### P4. `--local-user` w formie jednoserwerowej — ten PR

Wdrożenie jednoserwerowe mogło chodzić **tylko jako root**: parser odrzucał
flagę, `setup-server --local-user` tworzył konto ale go nie zapisywał (i słusznie
— konto jest decyzją per wdrożenie, nie ustawieniem hosta), a `cron_target_user`
bez `LOCAL_USER` zwracał roota.

Cała maszyneria pod spodem była już świadoma konta. Brakowało wyłącznie flagi.
Zrobione spójnie z formą zdalną: ta sama nazwa, ta sama gramatyka, ten sam
domyślny root z tym samym zdaniem, konto tworzone gdy brak, delegacja ZFS na
**każdym źródle i na celu**, blok do crontaba tego konta.

Dwie rzeczy, które wyszły przy okazji i musiały wejść razem:

- podgląd renderował się przez `bash $GENCRON` (kopia roota), a instalacja przez
  `gencron_as_target` (kopia konta). Gen-cron wypieka ścieżki z miejsca, gdzie
  leży, więc podgląd pokazywałby blok, który nigdy nie powstanie. Nieszkodliwe,
  póki lokalne mogło być tylko rootem — szkodliwe od chwili, gdy może nie być;
- cel jeszcze nie istnieje przed seedem, więc `zfs allow` na nim by padł.
  Tworzony jawnie, wąsko i pusto, żeby grant miał na czym wylądować — zamiast
  delegować rodzica, co oddałoby kontu całą pulę.

**Trzecia rzecz, którą sam wprowadziłem i cofnąłem, bo warto ją zapisać.**
Pierwsza wersja tworzyła brakujące konto **także przy zwykłym planie** — a plan
ma kontrakt „bez `--install`: planuje i pokazuje, nie instaluje nic", i konto
uniksowe nie jest niczym. Na runnerze linuksowym mój własny test założyłby
prawdziwego użytkownika komendą, która z definicji nie zmienia hosta.

**I dwie przyczyny, które wyszły dopiero na żywo, mimo zielonego CI.**

Pierwsza wersja przeszła wszystkie testy i **nie działała na hoście**: flaga się
parsowała, zmienna ustawiała, blok i tak lądował u roota. CI było zielone, bo
suita woła funkcję i sprawdza odmowy, a nie to, do czyjego crontaba trafia
prawdziwa instalacja.

`read_server_conf()` ustawia `LOCAL_USER=""` **bezwarunkowo** — zanim jeszcze
sprawdzi, czy `server.conf` da się odczytać — a `cmd_local_backup` woła ją, żeby
rozwiązać `CRON_CONFIG`. Wszystko między przypisaniem a użyciem tylko **czytało**
tę zmienną, więc grep po przypisaniach nie znajdował nic. Widać to dopiero
z sondą po obu stronach luki:

```
SONDA-0  LOCAL_USER=[zfsbackup]                       <- przy przypisaniu
SONDA-2  LOCAL_USER=[PUSTE]  cron_target_user=[root]  <- przed seedem
```

Pułapka **była już znana**: dwie ścieżki zdalne noszą komentarz „read_server_conf
just reset LOCAL_USER, so resolve it" i odtwarzają wartość po swoim wywołaniu.
Znana, udokumentowana w dwóch miejscach — i mimo to złapała trzeciego wołającego.
To argument, żeby ładowarka nie czyściła po cichu stanu, którego nie jest
właścicielem, ale to zmiana szersza niż ta poprawka.

Druga wyszła dopiero, gdy pierwsza zadziałała: kandydat configu to `mktemp`,
czyli `0600`, a renderuje go **konto**, nie root. Nieczytelny plik wychodził jako
`no sections found` — czyli jak zepsuty config, a nie jak problem uprawnień;
`Permission denied` było linijkę wyżej i łatwo je przeoczyć. Kandydat dostaje
`0644`, tak jak zainstalowany config: to opis datasetów i harmonogramów, nigdy
sekret, a konto musi go czytać przy każdym przebiegu.

Rozstrzygnięte tak: pod `--install` konto powstaje, przy planie **odmowa**.
Nie dlatego, że tak bezpieczniej, tylko dlatego, że plan nie miałby czego
pokazać — `gen-cron` wypieka ścieżki z kopii, która go uruchamia, więc podgląd
dla nieistniejącego konta mógłby wyjść wyłącznie z kopii roota i pokazywałby
blok, który nigdy nie powstanie. Pokazanie nieprawdy jest gorsze niż odmowa.

---

## Otwarte, w kolejności kosztu

### P5. Sync kopiuje to, czego nie zamawiałeś — NAJPILNIEJSZE

Jeden enrolment nazywający jeden dataset zreplikował **trzy** na ścieżki
tożsamościowe, w tym cudzy. Łańcuch trzech rzeczy:

1. szkic zakresu na źródle **kumuluje** wpisy między enrolmentami,
2. `--join` akceptuje **cały plik**, nie bieżące żądanie,
3. klient sync bierze listę z **zatwierdzonego zakresu**, nie z `--source`.

Skutek na produkcji: `hdd/lab4` ląduje pod `hdd/lab4` na kolektorze, gdzie może
już coś być.

**Proponowana poprawka.** Rozdzielić „co jest przyznane" od „co ta relacja
bierze". Relacja powinna nieść własny podzbiór zakresu, a `--source` w trybie
sync ma albo ten podzbiór wyznaczać, albo — jeśli ma pozostać tylko adresem
peera — **odmawiać bez jawnego wyliczenia**, zamiast brać wszystko. Do decyzji
właściciela, bo to zmiana semantyki `--source`.

Minimum, gdyby pełna zmiana miała czekać: enrolment sync **wypisuje listę
datasetów, które weźmie**, i pod `--yes` odmawia, jeśli jest szersza niż
`--source`. Nazwanie skutku przed jego wywołaniem jest tanie.

**Minimum ZROBIONE 2026-08-21.** `resolve_mode_datasets` loguje rozwiązaną listę
**bezwarunkowo** — dotąd `Zrodla:` w `cmd_seed` siedziało wewnątrz
`if [ "$yes" -ne 1 ]`, więc przebieg automatyczny ruszał prawdziwe dane nigdy
nie nazwawszy, co rusza. `assert_sync_scope_within_request` porównuje rozwiązaną
listę z `RUX_SOURCE` i **pod `--yes` odmawia**, wymieniając nadmiarowe datasety
i podając dwie drogi naprawy (`--draft-scope`/`--commit-scope` na źródle albo
ponowny enrolment z `--grant-remotely`). Bramkują obie komendy: `cmd_seed`, bo
przenosi dane raz, i `cmd_activate_client`, bo instaluje zadanie cykliczne —
jedna bez drugiej zostawia drogę, `activate` wchodzi wprost na zaseedowanego
klienta.

**Bez `--yes` celowo przepuszcza.** Przebieg interaktywny i tak wypisuje
`Zrodla:` i żąda `t`, więc operator, który przeczyta szerszą listę, może się na
nią świadomie zgodzić — przejęcie istniejącego szerszego grantu to realny
przypadek. `--yes` nie ma czytelnika i nie może zgodzić się na coś, czego nie
zobaczył.

**Czego to NIE naprawia — trzy ogniwa stoją.** Dataset nadal odpada z `--source`
przy wołaniu `add-client` (`zfs-backup.sh:6107`), źródło nadal szkicuje zakres
z pustego żądania, a `rux_verify_requested_scope` nadal wychodzi dla sync
(`:5812`), bo pyta o *pokrycie*, a boli *szerokość*. To jest siatka pod dziurą,
nie zaszycie dziury — semantyka `--source` czeka na decyzję właściciela.
Testy: `test/zfsbackup` 62a–62h.

### P6. Enrolment sync otwiera `vi` na peerze

`remote_scope_stage` uruchamia `${VISUAL:-${EDITOR:-vi}}` przez `ssh -t` po
udanym automatycznym joinie. Zmierzone: osiem minut z plikiem swap, przebieg
stał. Uratował limit czasu nałożony z zewnątrz, nie kod.

**Poprawka** jest ta sama co przy `--join` (O14): edytor tylko wtedy, gdy jest
terminal; bez terminala wypisać ścieżkę pliku i komendę do uruchomienia ręcznie.
`[ -t 0 ]` jest całym testem.

### P7. Self-sync przechodzi planowanie

`--source=<własny adres> --mode=sync` daje `rc=0`. `validate_remote_host`
(porównuje `/etc/machine-id`) żyje w silnikach, planer jej nie woła. Zbudujesz
konto, klucze i linie crona, a odmowa przyjdzie przy pierwszym jobie.

**Poprawka:** wołać tę samą kontrolę w planerze RUX, przed `add-client`.
Straż istnieje — chodzi tylko o drugie miejsce wywołania.

### P8. `remove-client` zabiera wspólny rekord parowania

Dwie relacje do tego samego peera dzielą `peers/<adres>.conf`. Usunięcie jednej
zostawia drugą w `seeding` z „no pairing manifest", a `remove-client` odmawia
usunięcia klienta w tym stanie — czyli druga relacja jest nieusuwalna własnym
czasownikiem.

**Poprawka:** przed usunięciem rekordu sprawdzić, czy inna relacja go nie
używa; jeśli używa — zostawić i powiedzieć, że został, bo dzieli go z `<nazwa>`.

### P9. Nagrobek nazywa dane, których już nie ma

`clean-relationships.sh --purge` wypisuje `DATA LEFT IN PLACE` także wtedy, gdy
dataset został skasowany chwilę wcześniej. Kosmetyczne, ale to komunikat
o stanie, który nie został sprawdzony — czyli ta sama rodzina co reszta.

**Poprawka:** sprawdzić istnienie przed wypisaniem, tak jak robi to już audyt.

### P10. `migrate-profile` i `audit-source-retention` nie umieją wybrać relacji

Dopisane 2026-08-21, poza macierzą — wyszło przy pytaniu o `server.conf`.
Zmierzone na żywo na pve2 i pve1 (metropolis), nie wywnioskowane z kodu.

Na hoście z dwiema relacjami żyją dwa configi i dwa crontaby:

| crontab | config | zawartość |
|---|---|---|
| `root` | `jobs.<host>.conf` | lab4 — 1 dataset |
| `zfsbackup` | `jobs.<host>.v4.conf` | produkcja — pve2: 4, pve1: 7 datasetów |

Obie komendy rozwiązują plik jako `${CRON_CONFIG:-$(default_cron_config)}`.
Pomijają krok adopcji `# Source:` z zainstalowanego bloku, który mają
`setup-server` i `activate-client`; nie czytają rekordu klienta; i **nie
przyjmują ani `--config`, ani `--local-user`** (`migrate-profile` zna tylko
`--yes`, `audit-source-retention` tylko `--apply --yes`). Nie ma czym w nie
wycelować.

Bez `server.conf` — a nie ma go na żadnym z pięciu hostów — zostaje sam
`default_cron_config()`, czyli config laba. Dalej `LOCAL_USER` jest puste,
więc `cron_target_user` zwraca `root`, więc
`assert_cron_config_matches_installed` porównuje config laba z blokiem roota,
**zgadza się i przepuszcza**. Straż działa poprawnie — sprawdza spójność
wewnątrz niewłaściwego zakresu.

Pomiar (`audit-source-retention` bez `--apply`, oba hosty):

```
Audyt retencji ZRODLA (config: /etc/zfs-snapshot-all/jobs.pve2.conf)
  aktywne pull-datasety (zarzadzane): 1
  Kazda aktywna relacja pull ma juz ograniczona retencje zrodla -- nic do dodania.
```

Opisał laba, produkcji nie otworzył.

**Waga, bez naciągania: dziś utajone, nie czynne.** Werdykt audytu i tak
wyszedłby ten sam, bo produkcyjne datasety to lokalne źródła, nie pull — audyt
produkcji też znalazłby zero. Ale `migrate-profile` **pisze**
(`atomic_replace_and_install`): przepisałby config laba, przeinstalował
crontab roota, zgłosił sukces i zostawił 7 produkcyjnych datasetów
niezmigrowanych bez ostrzeżenia.

Rodzina jak reszta listy: **fakt hostowy użyty jako dowód, o którą relację
chodziło.** `default_cron_config()` jest z czasów, gdy host miał jeden config;
konto jest per-relacja od dawna, a ta nazwa nigdy za tym nie poszła.

**Kształt naprawy — do ustalenia z właścicielem.** Dwie drogi, wykluczające
się tylko pozornie: (a) adopcja `# Source:` jak w `activate-client`, co
wybiera to, co faktycznie chodzi, ale nadal zgaduje konto; (b) wymuszony
`--config`/`--local-user`, co jest jawne, ale psuje wywołania bez argumentów.
Nie przesądzać przed decyzją.

---

## Lista wywołań komend

Pełny inwentarz z przebiegów jest w `docs/LAB5-KAMPANIA.md`. Skrót
w jednym miejscu, po jednej linii na kształt:

```bash
# jednoserwerowe, root, jawny cel
zfs-backup.sh --source=hdd/src --target=hdd/dst --install --yes

# jednoserwerowe, cel z server.conf (proweniencja wypisana)
zfs-backup.sh setup-server --target=hdd/dst
zfs-backup.sh --source=hdd/src --install --yes

# jednoserwerowe, konto delegowane            <- P4, nowe
zfs-backup.sh --source=hdd/src --target=hdd/dst --local-user=zfsbackup --install --yes

# dwuserwerowe, root, automatyczny join przez SSH
zfs-backup.sh --source=HOST:hdd/src --target=hdd/dst --name=N --install --yes
  # staje na akceptacji zakresu; na ZRODLE:
  cat /etc/zfs-snapshot-all/peers/<kolektor>.scope      # OBEJRZEC
  deploy.sh --commit-scope=<kolektor>
  # powtorzyc komende z gory

# dwuserwerowe, konto delegowane, join reczny
zfs-backup.sh --source=HOST:hdd/src --target=hdd/dst --name=N \
              --local-user=zfsbackup --manual-join --install --yes
  scp /root/scripts/pairing/<wsad>.tgz root@HOST:/root/
  # na ZRODLE: obejrzec wsad, potem
  deploy.sh --join=/root/<wsad>.tgz      # pyta, odpowiedz 't' -- TU zatwierdza zakres
  # powtorzyc komende z gory

# sync (mapowanie tozsamosciowe, bez --target)   <- uwaga P5
zfs-backup.sh --source=HOST:hdd/src --mode=sync --name=N --local-user=zfsbackup --install --yes

# rozbiorka
zfs-backup.sh remove-client N        # kolektor
deploy.sh --leave=<etykieta>         # zrodlo, PRZED recznym sprzataniem
gen-cron.sh --uninstall              # wdrozenie jednoserwerowe (brak relacji)
clean-relationships.sh               # audyt: co zostalo
clean-relationships.sh --purge-orphans --yes
```
