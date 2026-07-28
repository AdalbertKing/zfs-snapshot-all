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

## Otwarte tematy (świadomie nierozstrzygnięte)

- Pełna automatyzacja draft-configu (bez review) — do rozważenia później.
- Dokładny format paczki (tar vs katalog) i finalne nazwy flag — szczegóły
  implementacyjne, nie architektura.
- Czy `--join` ma coś aktywnie zwracać na hosta inicjujący (np. potwierdzenie
  do automatycznej weryfikacji), czy wystarczy że admin widzi sukces na
  ekranie.
- **Brak `--unpair` (trwałe zakończenie relacji).** Rotacja wymienia klucz,
  ale nie ma ścieżki na pełną dekomisję — koniec współpracy z hostem na
  zawsze (konto, delegacja, manifest, klucz — wszystko do usunięcia). Nie
  rozwiązujemy teraz, ale ma nie zniknąć z listy.
