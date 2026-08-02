# Twarde warunki startowe wdrożenia pve1 ↔ pve2

Stanowisko implementera do uzgodnienia z recenzentem, 2026-08-02.

> **Uwaga po REV-20260802-033 (napisane tego samego dnia, kilka minut później).**
> Ten dokument powstał **przed** przeczytaniem REV-033 i opisuje warunki wejścia
> procedury *takiej, jaka jest dziś w kodzie*. REV-033 niesie decyzje
> właściciela, które część z tego uchylają — przede wszystkim §2.3 (pairing
> offline jako droga normalna) i milczące założenie z §1, że zakres datasetów
> jest znany po stronie kolektora w chwili `--pair`. Punkty o nadawaniu
> uprawnień, przypiętym kluczu hosta, wykonywalności bloku i kolejności stanów
> zostają w mocy. Reszta jest do pogodzenia w odpowiedzi na REV-033 i ten
> dokument zostanie wtedy przepisany, nie dopisany.

Dokument opisuje **warunki wejścia** procedury, nie jej przebieg. Przebieg jest
w `DEPLOY-UX-AGREED-POSITION.md` i w `PROJECT_STATUS.md` §3b. Tu jest wyłącznie
to, co musi być prawdą **zanim** ktokolwiek uruchomi pierwszą komendę, i kto za
co odpowiada.

Każdy punkt jest oznaczony:

- **[JEST]** — wymuszone dziś przez kod, z miejscem w kodzie;
- **[PROPONUJĘ]** — moja propozycja zaostrzenia, do decyzji recenzenta;
- **[OTWARTE]** — pytanie, na które nie mam zdania bez jego argumentu.

---

## 0. Role i kierunek

pve1 = **appliance / kolektor**, pve2 = **źródło**. Transfer jest **pull**:
kolektor sięga po dane, źródło nie ma żadnego dostępu do kolektora. To nie jest
preferencja stylistyczna — to jest granica zaufania. Host trzymający kopie nie
oddaje kluczy hostowi, którego pilnuje.

Cały ruch inicjuje pve1. pve2 nie zna adresu pve1, nie ma do niego klucza i nie
musi.

---

## 1. Kto nadaje uprawnienia — zasada nadrzędna

**Każdy host nadaje uprawnienia u siebie, świadomą komendą, uruchomioną przez
człowieka na tym hoście.** Paczka pairingowa nigdy o uprawnienia nie prosi i
nigdy ich nie niesie.

**[JEST]** `--allow-quiesce` **nie jest** opcją `--pair` — `deploy.sh` odmawia
kodem 2 z komunikatem, że o zamrażaniu gości decyduje host, który uruchamia
`--join` (dla peera) albo zwykły `deploy.sh` (dla własnego konta).

**[JEST]** `--join` na pve2 nadaje **wyłącznie** zestaw wysyłkowy na dokładnie
wymienionych datasetach:

```
snapshot,destroy,send,hold,release,bookmark
```

Bez `receive`, bez `mount`, bez `create` — bo źródło niczego nie odbiera.
Zestaw zależy od **roli**, nie jest jedną płaską listą (`deploy.sh`, sekcja
`zfs allow` w `--join`).

**[JEST]** Quiesce jest **osobnym, opcjonalnym** krokiem na pve2:
`--allow-quiesce` (nadpisuje whitelistę) albo `--add-quiesce` (dokłada,
zachowuje cudze wpisy — REV-20260802-028). Zakres bierze się z **tej samej
listy datasetów** co replikacja, żeby nie mógł się rozjechać.

**[JEST]** Granica `zfs-backup.sh` / `deploy.sh` zostaje tam, gdzie postawił ją
REV-20260801-020: wrapper **nie woła** `deploy.sh` po nadanie uprawnień, tylko
wypisuje jeden uporządkowany blok naprawczy. Uzgodnione z właścicielem
2026-08-02 (opcja b). Powód jest asymetrią skutków: najgorszy dzisiejszy błąd
wrappera przepisuje crontab (odwracalne), po scaleniu poszerzałby grant
(nieodwracalne w praktyce, bo nikt tego nie zauważy).

---

## 2. Warunki, bez których procedura nie ma prawa ruszyć

### 2.1. Tożsamość i zaufanie transportu

**[JEST]** Klucz **dedykowany** dla relacji (`-K`), nie klucz osobisty konta.

**[JEST]** Klucz hosta peera jest **przypięty**, a `HostKeyAlias` jest stały —
relacja przeżywa zmianę adresu LAN → VPN bez ponownego zaufania. Brak
przypiętego klucza to `die`, dosłownie: *„refusing to proceed without one
(accept-new is not acceptable here)"*.

To jest jedyna ścieżka w projekcie, gdzie `accept-new` jest **zakazane**.
W `snapsend`/`snapget`/`delsnaps` jest domyślne i tak zostaje — tam relacja
istnieje już wcześniej.

**[JEST]** `GlobalKnownHostsFile=/dev/null` i `CheckHostIP=no` — oba znalezione
na żywo 2026-07-30, nie z lektury dokumentacji. Systemowy `ssh_known_hosts` jest
konsultowany **mimo** `HostKeyAlias` i przewraca weryfikację o niezwiązany wpis
sprzed lat; `CheckHostIP` dopisuje własne wpisy do pliku, który ma zawierać
dokładnie to, co ten program wygenerował.

### 2.2. Konta i wykonywalność

**[JEST]** Config **poza** checkoutem gita, w `/etc/zfs-snapshot-all/`, i
**czytelny dla konta docelowego** — sprawdzane, bo `gen-cron.sh` biegnie jako to
konto (`assert_config_readable_by_target`).

**[JEST]** Każdy skrypt w bloku musi być **wykonywalny przez to konto**
(`assert_block_runnable_by`). Warunek nie jest teoretyczny: `/root` ma 0700, więc
blok wskazujący na checkout roota daje `exit 126` na każdej linii — a idiom crona
kończy się `rm -f "$e"`, więc **każda linia i tak raportuje rc=0**. Cztery minuty
ciszy na pve2, 2026-08-01.

**[JEST]** Nieczytelny crontab przerywa procedurę. „Nie dało się odczytać" to nie
to samo co „jest pusty" — i to jest jedyna różnica między bezpiecznym
zaniechaniem a skasowaniem cudzej pracy.

**[JEST]** Instalacja nie może usunąć zadań, które konto już wykonuje
(`assert_target_block_not_clobbered`), ani zdublować bloku roota
(`assert_no_foreign_managed_block`).

### 2.3. Kolejność stanów

**[JEST]** `pending_enroll → seeding → seed_complete → endpoint_verified →
active`. **Cron instaluje się dopiero od `endpoint_verified`** — nigdy wcześniej.
Zadanie, które trafia do crona przed dowodem, że łącze działa, alarmuje o
własnym wdrożeniu.

**[JEST]** Pairing jest **offline**: `--pair` nikogo nie odpytuje, produkuje
paczkę. Pierwszy realny kontakt z peerem to `seed`. Konsekwencja, którą trzeba
nazwać wprost: **błędny adres albo brak `--join` po drugiej stronie wychodzi
dopiero na `seed`**, nie na `add-client`.

### 2.4. Dostarczanie kodu

**[JEST]** Wyłącznie godzinowy `git pull`. Ręczne skopiowanie skryptu na hosta
psuje `--ff-only` na stałe. Sześć checkoutów we flocie, wszystkie z gita.

---

## 3. Co dziś jest tylko ostrzeżeniem — a moim zdaniem nie powinno

To jest właściwa treść do uzgodnienia z recenzentem.

### 3.1. Odziedziczony grant szerszy niż relacja — **[PROPONUJĘ]**

`check_inherited_grants` idzie po każdym segmencie ścieżki i **ostrzega**, gdy
konto ma grant z przodka albo gdy nie ma jawnego grantu dokładnie na
wskazanym datasecie. Uzgodnione stanowisko (§11) mówi: raportuj osobno, nie
sugeruj izolacji, której nie ma, i **nigdy nie usuwaj cudzych grantów
automatycznie**. Zgadzam się z każdym słowem.

Ale ostrzeżenie w środku długiego wyjścia to nie jest warunek startowy.
Proponuję: przy `verify-endpoint` **twarda odmowa**, jeżeli konto ma dostęp z
przodka szerszy niż relacja, z jawnym `--i-know` do przełamania. Uzasadnienie:
to jedyny moment, w którym ktoś patrzy, a rozjazd między „relacja obejmuje trzy
datasety" a „konto i tak sięga całą pulę" jest dokładnie tym, czego nikt nie
zauważy przez rok.

### 3.2. Dataset nie istnieje na peerze przy `--join` — **[PROPONUJĘ]**

Dziś: `warn` + `skip`, reszta leci dalej. Czyli `--join` z literówką w nazwie
kończy się **sukcesem** i relacją o pustym albo niepełnym zakresie. Dowiesz się
o tym z braku snapshotów, czyli z monitora, czyli po godzinach.

Proponuję: **odmowa**, chyba że operator poda `--allow-missing`. Relacja, która
nie obejmuje tego, co miała obejmować, nie jest relacją — jest wpisem w pliku.

### 3.3. Whitelista quiesce a lista replikacji — **[JEST, do potwierdzenia]**

Dziś zakres quiesce bierze się z **tej samej** listy datasetów co replikacja i
uważam to za poprawne. Chcę tylko usłyszeć od recenzenta, czy zgadza się, że
rozdzielenie tych list (osobny `--quiesce-datasets`) byłoby **regresem**, a nie
elastycznością.

### 3.4. Kolektor na koncie dedykowanym — **[OTWARTE]**

Kod jest, testy przechodzą w kształcie rootowym, **na żywo nie było**. To jest
dziś największa realna dziura w tej procedurze i zgłaszam ją sam, zanim
zapyta. Pytanie do uzgodnienia: czy warunkiem domknięcia pakietu jest przebieg
na żywo z kontem po **obu** stronach, czy wystarczy po stronie źródła
(zweryfikowane) plus test w kształcie rootowym na kolektorze.

Moje zdanie: potrzebny jest przebieg na żywo. Wszystkie cztery defekty z
2026-07-25 i wszystkie trzy z migracji były niewidoczne dla roota.

---

## 4. Czego nie otwieram ponownie

Uzgodnione wcześniej, nie zamierzam do tego wracać bez nowego argumentu:

- **jedna kadencja wysyłki + jedna drabina GFS + jeden monitor** na najdrobniejszym
  tierze (REV-016). `-G` kubełkuje po czasie i nie patrzy na prefiks, więc
  dodatkowe kadencje nie definiują tierów, tylko dokładają transfery;
- **brak automatycznej instalacji draft-configu** bez przeglądu administratora;
- **tryb ekspercki zostaje** — `--pair/--join` ręcznie, `--as=root`, ręczne INI,
  własne flagi SSH. Nowa warstwa jest domyślną prostą drogą, nie odebraniem
  możliwości.

---

## 5. Stan faktyczny, na którym stoję

Pełny cykl przeszedł **na żywo 2026-08-01** na metropolis (pve1 kolektor jako
root, pve2 źródło): `setup-server` → `add-client` → paczka → `--join` → `seed`
(40 MB realnego transferu) → `verify-endpoint` → `activate-client` → uruchomienie
wszystkich trzech wygenerowanych linii → `remove-client` → teardown. 15 → 18
linii crona, każda produkcyjna co do znaku, po teardownie crontab **identyczny**
ze zrzutem sprzed testu, zero pozostałości po obu stronach.

Ten przebieg znalazł błąd, którego żaden test lokalny znaleźć nie mógł: drugi
argument `snapget.sh` to baza **lokalna**, a wrapper podawał ścieżkę końcową —
seed lądował poziom za głęboko, `base=null`, pełny transfer w kółko, a
`verify-endpoint` meldował sukces, bo szukał w tym samym złym miejscu.

Stan floty na 2026-08-02: cztery hosty, wszystkie na kontach delegowanych, grant
quiesce na każdym, zaufanie ssh między kontami pary w **obu** klastrach,
kampania `remote` 145/145 jako root **i** jako konto na obu parach.
