# Parowanie dwóch serwerów (master/servant) — plan projektowy

Stan: **dyskusja zamknięta, szkielet ustalony**. Szczegóły oznaczone niżej jako
"do dopieszczenia później" są świadomie odłożone — celem tego dokumentu jest
spójny, logiczny szkielet, nie kompletna specyfikacja.

## Kontekst

`deploy.sh` dziś zakłada, że dwa hosty już się znają (np. przez klaster
Proxmox, które i tak dają wzajemne zaufanie roota). Cel: rozszerzyć go o
wdrożenie na dwóch serwerach, które **nie mają żadnego wcześniejszego
zaufania między sobą** (niekoniecznie klaster Proxmox, może to być połączenie
po WAN).

## Role

- **pull (domyślna)** — serwer backupu łączy się do źródła, wykonuje
  `snapget.sh`, rozłącza się. Preferowany model dla docelowego serwera
  backupu (łączy się cyklicznie, nie stoi otwarty jako cel wejściowy).
- **push** — istniejący dziś model (`snapsend.sh` ze źródła na cel). Zostaje
  dostępny jako opcja, bo dokładnie tak działają obecne klastry.

Kierunek klucza SSH zależy od roli — generuje go **zawsze ten host, który się
łączy** (kolektor przy pull, źródło przy push). Nigdy dwa klucze na tę samą
relację.

**Lokalny rejestr peerów po stronie inicjatora.** Symetrycznie do manifestu
tworzonego przez `--join` na drugiej stronie, host wykonujący `--pair`
prowadzi własny rejestr (ten sam wzorzec ścieżki:
`/etc/zfs-snapshot-all/peers/<label>.conf`, tylko z perspektywy inicjatora):
który plik klucza obsługuje którego peera, aktualny target, i czy trwa
rotacja. Bez tego `--rotate`/`--revoke-old` nie mają skąd wiedzieć "czy ta
relacja jest w trakcie rotacji" — to na ten rejestr się powołują.

## Konta: root vs delegowane

Dwa tryby, oba wspierane:

- **`--as=root`** — parytet z obecnym stanem (klastry Proxmox). Klucz roota
  jednej strony trafia do `authorized_keys` roota drugiej. Świadoma
  rezygnacja z izolacji — akceptowalna tylko gdy hosty i tak już sobie w pełni
  ufają (np. przez klaster).
- **Delegowane konto per peer (domyślne)** — nazwa zawiera etykietę drugiej
  strony, np. `zfsbackup-pve1` na hoście źródłowym dla relacji z kolektorem
  `pve1`. Każda relacja = osobne konto, osobny `authorized_keys`, osobna
  delegacja `zfs allow` — zero wspólnego stanu między różnymi relacjami tego
  samego hosta (np. pve2 może mieć niezależny, wcześniejszy układ z pve3 i
  pozostaje nietknięty).

Nazwa konta pochodzi z etykiety kolektora zapisanej w paczce parowania, nie z
generycznego `zfsbackup`.

**Izolacja kończy się na koncie + `zfs allow`, świadomie nie na powłoce.**
Skradziony klucz i tak daje pełną interaktywną powłokę bash jako to konto
(bez hasła, ale z shellem) — nie tylko dostęp do operacji ZFS. Rozważane było
wymuszenie wąskiego zestawu komend przez `command="..."` w `authorized_keys`;
**decyzja: zostajemy przy pełnej powłoce**, jak w obecnym modelu delegowanego
konta. Prostota ważniejsza niż to dodatkowe zawężenie na tym etapie.

**Zestaw uprawnień `zfs allow` zależy od roli, nie jest jeden uniwersalny:**
- **pull** — peer dostaje datasety **źródłowe**, potrzebuje uprawnień
  *wysyłających*: `snapshot,destroy,send,hold,release,bookmark`.
- **push** — peer dostaje datasety **docelowe**, potrzebuje uprawnień
  *odbierających*: `receive,create,mount,rollback,canmount` (bez `bookmark`
  — bookmarki powstają po stronie wysyłającej, nie odbiorczej).

`--join` musi wybrać właściwy zestaw na podstawie roli zapisanej w
`peer.conf`, nie kopiować istniejącego blankietowego `ZFS_PERMS` z Fazy 8g
1:1 (ten zestaw powstał dla innego przypadku — jednego konta obsługującego
obie strony lokalnie).

### Konto lokalne: `--local-user` (dodane 2026-07-29)

Powyższe dotyczy konta **na peerze**. Osobne, wcześniej przeoczone pytanie
brzmi: *jakie konto na hoście inicjującym uruchomi wygenerowane zadanie?*
`--as` na to nie odpowiada, a domyślna odpowiedź "root" była wpisana w kod
milcząco — przez to, że klucz parowania leży w `/root/.ssh/pairing` (0700).

`--local-user=NAME` odpowiada na nie wprost i robi dwie rzeczy, których
wcześniej nie robił nikt:

1. Instaluje **czytelną dla tego konta kopię** klucza parowania w
   `~NAME/.ssh/pairing-<label>_ed25519` (0600, właściciel NAME).
   `/root/.ssh/pairing` zostaje 0700 roota — przechodzi tylko ten jeden klucz
   tej jednej relacji. `--draft-config` emituje `-K` wskazujące na kopię.
2. Instaluje kopię **przypiętego klucza hosta** peera w
   `~NAME/.ssh/pairing-<label>_known_hosts` (patrz niżej).
3. Dla `role=pull` deleguje `ZFS_PERMS` na **lokalny korzeń relacji**
   (`<target>/<label>`). To lustrzane odbicie tego, co `--join` robi po
   drugiej stronie, i po prostu go brakowało: `--join` delegował stronę
   źródłową na peerze, a stronę odbiorczą tutaj nie delegował nikt. Jako root
   niewidoczne — pierwszy delegowany przebieg umierał na
   `cannot receive: permission denied`.

Rotacja: kopia **nie jest** ruszana przez `--rotate` (nowy klucz jest jeszcze
niesprawdzony, cron ma dalej chodzić na starym), tylko przez `--revoke-old` —
w jedynym momencie, gdy nowy klucz jest zarazem zweryfikowany i promowany.
Dzięki temu obietnica "linie crona nie wymagają zmiany" obowiązuje też dla
konta delegowanego, nie tylko dla roota. Sprawdzone na żywo pve1↔pve2:
to samo, niezmienione zadanie przechodzi przed rotacją, w jej trakcie i po
`--revoke-old`.

### Klucz hosta dociera do zadania (dodane 2026-07-29)

`--pair` weryfikuje klucz hosta peera ręcznie: `ssh-keyscan`, wypisany odcisk,
linia „CONFIRM this". Do 2026-07-29 ta cała ceremonia trafiała **wyłącznie do
`/root/.ssh/known_hosts`**, a wygenerowane zadanie tego pliku nie otwierało:
draft nie emitował `-k`, więc `snapget.sh`/`snapsend.sh` szły na domyślnym
`accept-new` — czyli ufały temu, co odpowiedziało przy ich własnym pierwszym
połączeniu. Dla `--local-user` konto zadania miało w dodatku swój własny,
pusty `known_hosts`. Weryfikacja odbywała się i nie chroniła niczego.

Ta sama klasa błędu co `-K` przed poprawką, więc i ta sama poprawka:

- klucz hosta ląduje teraz **także** w pliku per-relacja
  `/root/.ssh/pairing/<label>_known_hosts` — dokładnie jeden klucz, ten
  sprawdzony przy parowaniu, zamiast wszystkiego, co `accept-new` uzbierał
  przez lata w `known_hosts` konta,
- `--local-user` dostaje jego kopię (0600, właściciel konta),
- `--draft-config` emituje `-k <ten plik>` obok `-K`.

`/root/.ssh/known_hosts` dalej jest zapisywany — czyta go własny `ssh`
deploy.sh (`--revoke-old` łączy się z `StrictHostKeyChecking=yes`).

Klucz hosta **nie rotuje** razem z kluczem parowania, więc `--rotate` go nie
dotyka; `--revoke-old` odświeża kopię przy okazji promocji nowego klucza.

Jeden świadomy wyjątek: jeśli pliku z przypiętym kluczem nie ma (parowanie
sprzed tej zmiany), draft **nie emituje `-k`** i mówi o tym w logu i w samym
pliku. `-k` wskazujące na nieistniejący plik zamienia `accept-new` w zadanie,
które nie połączy się nigdy — to gorszy wynik niż to, co miało naprawić.

### Port też trafia do zadania (dodane 2026-07-29)

Manifest od początku miał `PEER_SAVED_PORT`, własne wywołania `ssh` w deploy.sh
go używały — a jedyna rzecz, która trafia do crona, nie. Przy porcie ≠ 22
`--draft-config` emituje teraz `-p <port>` obok `-K`/`-k`. Dla 22 nie emituje
nic: `-p 22` w każdej sugerowanej linii to szum, a szum uczy ludzi nie czytać
flag.

Te dwie flagi są sprzężone. `ssh-keyscan -p N` zapisuje wpis jako `[host]:N`,
więc zadanie bez `-p` nie tylko poszłoby na zły port — nie znalazłoby też
przypiętego klucza i padło na `StrictHostKeyChecking=yes`.

Przy okazji: `"22"` wygląda tak samo jak brak `--port`, więc ponowne `--pair`
albo `--rotate` cicho cofało niestandardowy port do domyślnego (dokładnie ten
dryf, przed którym manifest chroni już rolę/target/`--as`). Teraz podany
`--port` wygrywa, a niepodany dziedziczy z manifestu.

### Dekomisja: `--unpair` (dodane 2026-07-29)

Rotacja wymieniała klucz; nic nie kończyło relacji. Ręcznie trzeba było pamiętać
o dwóch plikach klucza, przypiętym kluczu hosta, manifeście, delegacji lokalnej,
dwóch kopiach pod kontem zadania i czterech rzeczach na peerze — a zapominana
jest zwykle delegacja, czyli konto z prawem zapisu do datasetu, którego już nikt
nie pilnuje.

`--unpair --peer=NAME` sprząta **tylko stronę lokalną** i wypisuje komendy do
uruchomienia na peerze. Jednostronnie, w przeciwieństwie do `--revoke-old`:
w momencie dekomisji nie ma powodu zakładać, że kanał ssh jeszcze działa (często
to jest właśnie powód dekomisji), a zakładanie i kasowanie kont na cudzej
maszynie przez łącze, które właśnie rozbieramy, to zły domyślny wybór.

Trzy rzeczy, których **nie** robi, każda celowo:

- **Nie rusza danych.** Backup, który przeżywa relację, to przypadek normalny,
  nie awaria. Kasowanie go zrobiłoby z `--unpair` najgroźniejszą flagę w tym
  skrypcie.
- **Nie rusza `/root/.ssh/known_hosts`.** Przypięty klucz hosta to nasz zapis
  o tym, kim oni są, nie uprawnienie dla nich — i może już z niego korzystać coś
  innego. Komenda usunięcia jest wypisana.
- **Nie zdejmuje grantów z przodków** (patrz niżej).

Odmawia, dopóki jakikolwiek crontab odwołuje się do parowania. Usunięcie klucza
spod żywej linii crona nie kończy relacji — zamienia ją w zadanie, które pada co
noc i o tym mailuje. Komunikat kieruje do configu `gen-cron.sh`, nie do crontaba,
bo skasowanie samej linii crona pozwala następnemu `--install` wstawić ją z
powrotem.

Rotacja w toku jest obsłużona, nie odrzucona: peer ma wtedy dwa autoryzowane
klucze i instrukcja wymienia oba.

**Znalezione na żywo, nie z lektury:** `zfs allow` dziedziczy, więc cofnięcie
grantu, który zrobiło parowanie, **nie znaczy, że konto straciło dostęp**. Na
pve1 cel leżał pod `hdd/backuptest_targets`, który miał już grant
`Local+Descendent` dla tego samego konta z niezwiązanej pracy. `--unpair`
zalogował „revoked", a sekundę później to konto zrobiło snapshot tego datasetu.
Linia logu była prawdziwa i myląca naraz — czyli najgorszy rodzaj poprawnego
komunikatu, bo to na nim ktoś opiera decyzję, że izolacja zniknęła. Teraz jest
to wykrywane i raportowane (z nazwą przodka), ale nie usuwane: cudzy grant nie
jest nasz do zdejmowania. Ta sama pułapka dotyczy strony peera i jest wypisana
w instrukcji.

### Nazwa peera a DNS: `--allow-public-peer` (dodane 2026-07-29)

`--peer` trafia prosto do `ssh-keyscan`, którego całym zadaniem jest zaufać
temu, co odpowie. Gdy nazwa jest zła, parowanie **się nie wywala — udaje się
z kimś innym**: przypina cudzy klucz hosta, a następny `--draft-config`
wysyła tam klucz parowania.

To nie jest teoria. Na metropolis `pve2` z pve1 nie ma wpisu w `/etc/hosts`,
więc resolver dokleja domenę wyszukiwania i `getent hosts pve2` odpowiada
**czterema publicznymi adresami** niezwiązanego, prawdziwego `metropolis.net`.

`--pair` odrzuca teraz dwa odciski tej awarii:
- nazwa rozwiązująca się na **więcej niż jeden adres** (peer ma jeden;
  przypadek z domeną wyszukiwania rutynowo ma kilka),
- nazwa rozwiązująca się na **adres publiczny** — `--allow-public-peer`
  pozwala świadomie wrócić do tego dla prawdziwego peera przez WAN.

Literalny adres IP jest zwolniony z obu kontroli: żadne rozwiązywanie nazwy
się nie odbyło, więc nie ma czemu pójść źle.

## Proces parowania

### Krok 1 — `--pair` na hoście inicjującym (tym co się łączy)

```
./deploy.sh --pair --role=pull --peer=pve2 \
    --datasets="rpool/data rpool/vms" \
    --target=hdd/backups \
    [--as=root]
```

1. Fazy 1-7 jak dziś (zależności, repo, alerting, capacity) — bez zmian,
   idempotentnie.
2. `ssh-keyscan pve2` → fingerprint wypisany do wizualnego potwierdzenia →
   zapis do `known_hosts`. Nie wymaga żadnego wcześniejszego zaufania (to
   nieautoryzowane zapytanie do sshd), więc nie dodaje ręcznego kroku w
   drugą stronę.
3. Generuje **dedykowaną parę kluczy tylko dla tej relacji**
   (`id_ed25519_pve2`), nigdy wspólną dla wielu peerów.
4. Pakuje wsad: pubkey + `peer.conf` (rola z punktu widzenia drugiej strony,
   lista datasetów, nazwa proponowanego konta, port, `--as` tryb).
5. Wypisuje gotową komendę scp/pscp do ręcznego przeniesienia.

`--target` — dataset docelowy, na który spływają snapshoty. Podawany **po
stronie, która odbiera dane**:
- pull: lokalny dataset na kolektorze (tym samym hoście co `--pair`).
- push: dataset zdalny (na peerze) — sama flaga ta sama, interpretacja
  zależy od `--role`.

Konwencja nazewnictwa (już ustalona wcześniej w projekcie):
`<target>/<host-źródła>/<ścieżka-datasetu>`, np.
`hdd/backups/pve2/rpool/data`.

**Kto tworzy brakującego rodzica (`zfs create -p`) zależy od roli:**
- **pull** — target jest lokalny dla `--pair`, więc `--pair` tworzy go od
  razu, w tym samym kroku.
- **push** — target jest zdalny (na peerze), a w momencie `--pair` nie ma
  jeszcze żadnego zaufania do peera — nie da się tam nic zdalnie utworzyć.
  Tworzenie przesuwa się do `--join`, który fizycznie działa już na
  właściwym hoście i zna docelową ścieżkę z `peer.conf`.

### Krok 2 — ręczny transfer

Admin ręcznie kopiuje paczkę (scp/pscp) na drugi host i loguje się tam
konsolowo. Brak automatycznego kanału — na starcie nie ma żadnego zaufania
między samymi hostami backupu (tylko admin ma dostęp do obu z zewnątrz).

### Krok 3 — `--join` na drugim hoście

```
./deploy.sh --join=/path/pve1-to-pve2.tgz
```

1. Fazy 1-7 jak dziś, jeśli jeszcze nie zrobione.
2. Czyta `peer.conf`.
3. Tworzy izolowane konto (albo dopisuje do roota, jeśli `--as=root`) —
   **nigdy nie rusza innych kont/relacji na hoście**.
4. Dopisuje pubkey do `authorized_keys` (append, dedup po treści klucza,
   nigdy nadpisanie).
5. `zfs allow` tylko na wskazanych datasetach, tylko dla tego konta.
6. Zapisuje manifest w `/etc/zfs-snapshot-all/peers/<label>.conf` — ślad że
   ta relacja istnieje, z jaką listą datasetów, żeby kolejne uruchomienia
   (patrz niżej) wiedziały co już przyznano. Manifest trzyma **identyfikator
   peera (fingerprint klucza), nie tylko etykietę** — to jedyny sposób żeby
   odróżnić "ponowne sparowanie TEJ SAMEJ relacji" od przypadkowej kolizji
   nazw (dwie różne relacje, ta sama etykieta hosta z jakiegoś powodu). Jeśli
   konto o danej nazwie już istnieje, ale fingerprint w manifeście się nie
   zgadza z tym z paczki — `--join` odmawia i każe rozwiązać ręcznie, zamiast
   zgadywać.
7. **Nie dodaje żadnych linii cron** — to zostaje ręczne, jak dziś w Części 5.

### Krok 4 — ręczna linia cron na inicjatorze

Jak dziś: admin dopisuje `snapget.sh`/`snapsend.sh` z odpowiednim `-K
<identity-file>` i kontem zdalnym, testuje `-n` przed produkcją.

## Draft-config (propozycja, nie automat)

Po udanym `--join` (kanał już działa nowym kluczem), `--pair`/`--join` może
pobrać listę datasetów z drugiej strony i wygenerować **plik `.suggested`**
— szkic INI dla `gen-cron.sh`, jeden stanza per dataset, z sensownymi
domyślnymi wartościami.

**Nigdy nie instalowany automatycznie.** Admin przegląda, usuwa co nie
powinno być backupowane, poprawia resztę, przenosi do istniejącego
prywatnego repo `cron-configs`, dopiero potem `gen-cron.sh --install`.
Powód: ślepe wygenerowanie configu dla każdego znalezionego datasetu złapie
też to, co nigdy nie powinno trafić do backupu (swap, szablony, cudze
scratch datasety) — dokładnie ta pułapka, przed którą projekt już świadomie
ostrzega w Części 5 `deploy.sh`.

Polityka "jak" (`-r`/`-R`, `-G`/`gfs_pattern`, częstotliwość retencji)
**celowo nie jest flagą `--pair`** — żyje wyłącznie w INI `gen-cron.sh`, które
już to w pełni obsługuje. Draft z niej korzysta, admin dopieszcza przed
instalacją. Dwa istniejące zabezpieczenia łapią to, co draft zostawi puste:
ostrzeżenie o dziecku bez `-r`/`-R`, odrzucanie pustych/brakujących pól
configu.

**Odłożone do rozważenia później:** pełna automatyzacja (config
wygenerowany i zainstalowany bez etapu review). Świadomie nie decydujemy
teraz.

**Granica z `gen-cron.sh`:** parowanie kończy się na wygenerowaniu pliku
`.suggested` — nie woła `gen-cron.sh`, nie dotyka crontaba. Jedyna zależność
to zgodność SKŁADNI draftu z aktualnym formatem INI (jednokierunkowo: draft
naśladuje gramatykę gen-crona, nigdy odwrotnie). Praca nad `gen-cron.sh`
(instalacja, logika crona) może toczyć się równolegle bez ryzyka kolizji,
dopóki sama gramatyka INI nie zmieni się w sposób niekompatybilny z tym co
generator draftu już produkuje.

## Wielokrotne uruchomienia (idempotencja)

Ponowne `--pair` dla tej samej relacji, bez `--rotate`:
- klucz **nie jest regenerowany** (regeneracja unieważniłaby zaufanie już
  ustawione na drugiej stronie),
- zmiana `--datasets` aktualizuje lokalny zapis i wypisuje nowy wsad z
  uaktualnioną listą — ten sam klucz,
- `--join` na drugiej stronie **dokłada** delegację na nowe datasety, nigdy
  nie odbiera automatycznie tego, czego nowy wsad nie wymienia (tylko
  ostrzega: "wsad chce mniej niż jest przyznane, usuń ręcznie").

Zasada ogólna: automatyczne jest tylko dodawanie, odbieranie dostępu zawsze
jawne.

## Rotacja klucza

Trzy fazy, zero okna przestoju:

1. `--pair --peer=pve2 --rotate` — generuje **nowy** plik klucza obok
   starego (stary zostaje), pakuje wsad z nowym pubkeyem, ta sama
   nazwa konta/delegacja.
2. Transfer + `--join` na drugiej stronie — dopisuje nowy pubkey, **stary
   nadal działa równolegle**.
3. Weryfikacja: dry-run z nowym kluczem (`-K id_ed25519_pve2.new -n`).
4. `--pair --peer=pve2 --revoke-old` — jawna, osobna komenda. Usuwa
   **dokładnie tę linię klucza**, którą sam zapisał w manifeście przy
   `--rotate` (nie przeszukuje, nie zgaduje), plus lokalny stary plik
   klucza. Działa tylko gdy lokalny stan mówi "rotacja w toku" — nie da się
   odpalić przypadkiem na relację, która nie jest w trakcie rotacji.

## Podsumowanie odpowiedzialności

| Element | Odpowiada za |
|---|---|
| `--pair` / `--join` | kto z kim, jakie zaufanie, jakie datasety, gdzie docelowo (target) |
| manifest peer (`/etc/zfs-snapshot-all/peers/`) | co już przyznano tej konkretnej relacji |
| draft `.suggested` INI | punkt startowy do przeglądu, nie finalna decyzja |
| `gen-cron.sh` INI (w `cron-configs`) | cała polityka: harmonogram, `-r`/`-R`, `-G`, retencja |
| ręczna Część 5 | linie cron per host, tak jak dziś |

## Wariant B: inicjacja z pve1, pół-automatyczny zwrot paczki (propozycja, NIEZAIMPLEMENTOWANE)

Status: **dyskusja projektowa, nie architektura zamknięta jak reszta dokumentu**. Zapisane
żeby nie zgubić wniosków, do rozstrzygnięcia razem z resztą "Otwartych tematów" niżej.

Alternatywa dla sekcji "Proces parowania" powyżej, rozważana pod kątem: (a) kto generuje klucz
i dlaczego to musi zostać bez zmian, (b) jak zredukować ręczne kroki bez osłabienia modelu
zaufania, (c) jak domknąć problem, że `--target` (dziś flaga na hoście inicjującym) wymusza
znajomość ścieżki lokalnej w configu generowanym po drugiej stronie.

### Sekwencja

1. **pve1** (lokalnie, zero sieci): generuje dedykowany klucz dla tej pary jak dziś, ale pakuje
   do małej paczki init **także `--target`** (np. `hdd/backups`), nie tylko pubkey. Transfer
   ręczny (jak dziś — w tym miejscu nie istnieje żaden kanał do zautomatyzowania, patrz niżej).
2. **pve2**: `join --peer=pve1 --datasets="..." <paczka_init>` — nadaje `zfs allow` na
   wskazane datasety (jeden przebieg, nie osobny "tryb akceptacji": uruchomienie `join` ze
   świadomie podanymi `--datasets` JEST punktem decyzji, rozbijanie go na dwa kroki nie dodaje
   nic). Ponieważ `target` przyszedł już w kroku 1, `join` buduje config z **w pełni
   rozwiązanymi ścieżkami** (`hdd/backups/pve2/rpool/data`) — zero placeholderów, zero
   potrzeby wprowadzania templatingu do `gen-cron.sh` (którego nagłówek explicite deklaruje
   "no magic: a target is always a path you wrote down"). `join` wypisuje też na **własną
   konsolę pve2** fingerprint swojego klucza hosta, do ręcznego przeniesienia w kroku 3.
3. **pve1** ściąga paczkę zwrotną (config + host key pve2) — patrz automatyzacja niżej — i robi
   `snapget.sh -n` (dry-run) przed `gen-cron.sh --install`.

### Dlaczego krok 1→2 nie może być zautomatyzowany

W tym momencie nie istnieje żaden kanał między hostami — zero zaufania w obie strony.
Automatyzacja transferu wymagałaby wprowadzenia nowego mechanizmu zaufania (współdzielony
sekret, otwarty port, cokolwiek) w miejsce ręcznego przeniesienia — to nie jest przyspieszenie
tego samego kroku, to inny model bezpieczeństwa. Zostaje ręczny z definicji problemu.

### Krok 2→3: częściowa automatyzacja jest możliwa, ale fingerprint musi zostać ręczny

Po zakończeniu kroku 2 pve2 ma już w `authorized_keys` pubkey pve1 dla tej relacji — pve1 (mając
świeży klucz prywatny) **może się już połączyć**. Sam transfer bajtów paczki zwrotnej może więc
być automatyczny:

```bash
ssh -o StrictHostKeyChecking=accept-new -i id_ed25519_pve2 zfsbackup-pve1@pve2 \
    'cat /path/return-package.tgz' > return-package.tgz
```

**Ale** `accept-new` przy pierwszym połączeniu to ten sam TOFU, który już raz zawiódł na
metropolis (DNS dokleja domenę wyszukiwania, `pve2` rozwiązuje się na cztery publiczne adresy
`metropolis.net` zamiast jednego). Fingerprint hosta pve2 dołączony do TEJ SAMEJ automatycznie
ściąganej paczki nic nie chroni — atakujący pośrodku podstawiłby swój klucz i swój "zgodny"
fingerprint naraz. **Zasada: fingerprint musi dotrzeć kanałem niezależnym od tego, który
weryfikuje.**

Niezależny kanał już istnieje: admin uruchamiający `join` na pve2 w kroku 2 siedzi przy/jest
połączony z pve2 jakąś inną, już zaufaną drogą (konsola, IPMI, istniejące SSH) — to jest kanał
inny niż nowa relacja pve1↔pve2. `join` wypisuje na ten ekran fingerprint hosta pve2; admin
przenosi tę jedną krótką linię (nie plik) do pve1, dowolnie (głos, czat, wklejka).

Na pve1 **reużyj dokładnie mechanizm już zaimplementowany w `--pair`** (ssh-keyscan → wypisany
fingerprint → linia "CONFIRM this", patrz Krok 1 procesu parowania wyżej) zamiast przechodzić
prosto do `accept-new` + trwały zapis:

```bash
ssh-keyscan -p "$PORT" "$PEER" > /tmp/scan.$$
fp=$(ssh-keygen -lf /tmp/scan.$$)
echo "pve2 przedstawia: $fp"
echo "Porownaj z odciskiem wypisanym na konsoli pve2 pod koniec join."
read -rp "Zgadza sie? [tak/nie] " ans
[ "$ans" = tak ] || die "fingerprint nie potwierdzony -- przerywam, nic nie pobrane"
cat /tmp/scan.$$ >> "$PINNED_KNOWN_HOSTS"
```

Dopiero po przypięciu klucza pve1 robi automatyczne pobranie paczki zwrotnej.

**Wariant nieinteraktywny (pod przyszłe GUI z listą par):** zamiast promptu `read`, flaga
`--expect-fingerprint=SHA256:xxx` — GUI/admin wpisuje tam string przeczytany z konsoli pve2 (to
samo źródło, ten sam niezależny kanał, tylko przez pole formularza zamiast terminala):

```bash
[ "$fp" = "$EXPECT_FINGERPRINT" ] || die "fingerprint mismatch: got $fp, expected $EXPECT_FINGERPRINT -- refusing, possible MITM"
```

### Odrzucone: CA/certyfikat klucza hosta

Rozważane i odrzucone: pve2 podpisuje własny klucz hosta certyfikatem CA, pve1 ufa automatycznie.
Eliminuje ręczny krok całkowicie, ale wymaga wcześniej ustanowionego zaufania do CA — czyli z
powrotem problem kroku 1→2, tylko przesunięty o jeden poziom wyżej. Nie warto komplikować dla
scenariusza z jednym, jednorazowym ręcznym transferem paczki init.

## Otwarte tematy (świadomie nierozstrzygnięte)

- Pełna automatyzacja draft-configu (bez review) — do rozważenia później.
- Dokładny format paczki (tar vs katalog) i finalne nazwy flag — szczegóły
  implementacyjne, nie architektura.
- Czy `--join` ma coś aktywnie zwracać na hosta inicjujący (np. potwierdzenie
  do automatycznej weryfikacji), czy wystarczy że admin widzi sukces na
  ekranie.
- **Wariant B (sekcja wyżej) vs. proces parowania opisany w Częściach 1-4**:
  wybór między nimi (albo świadome utrzymanie obu jako opcji `--initiator=collector|source`)
  jest do podjęcia razem z resztą otwartych tematów, nie zdecydowany teraz.
- **2026-07-30, dalsza dyskusja o uproszczonym UX wdrożenia** (`docs/discussions/DEPLOY-UX-*.md`,
  `docs/discussions/DEPLOY-UX-IMPLEMENTER-NOTES.md`) argumentuje przeciwko Wariantowi B z tego
  samego powodu, dla którego był tu wahaniem, nie decyzją: pve2 nie zna polityki pve1 (retencja,
  harmonogram, limity), więc nie powinien budować finalnego configu. Implementer rekomenduje tam
  oznaczenie Wariantu B jako superseded-by-discussion, nie skasowanie — patrz te pliki po
  rozstrzygnięcie.
