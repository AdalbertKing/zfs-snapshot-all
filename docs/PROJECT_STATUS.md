# PROJECT_STATUS — faktyczny stan projektu

> **To jest dokument ŻYWY, nie protokół z jednego dnia.**
> Odświeżany przez implementera na końcu **każdego** etapu, zanim etap zostanie
> zgłoszony jako zrobiony. Jeżeli data poniżej jest starsza niż ostatni commit
> zmieniający zachowanie — dokument jest zepsuty i to jest defekt do zgłoszenia,
> nie drobiazg. Obowiązek jest zapisany w `CLAUDE.md` i przypomina o nim
> `./test/impact.sh` jako obowiązek ręczny `project-status`.

- Data odświeżenia: **2026-07-31**
- Zweryfikowano przeciw: `c3d664c` **plus commit niosący ten dokument** —
  dokument nie może podać własnego SHA, więc podaje rodzica; to jest konwencja,
  nie niedopatrzenie
- Ostatnia zmiana zachowania produkcyjnego: kolejność commitu grantu (REV-012), commit niosący ten dokument
- Repozytorium: `AdalbertKing/zfs-snapshot-all`
- Tryb pracy: tymczasowo bezpośrednio do `main`, decyzją właściciela
- Poprzedni **uzgodniony** punkt bazowy: `388a78e` z 2026-07-30 (sekcja 8)
- Status ogólny: **brak otwartych blockerów; grant przetestowany end-to-end na żywym hoście 2026-07-31; jeden sporny finding czeka na werdykt recenzenta**

## 1. Co jest wdrożone, gdzie i w jakiej wersji

Cztery żywe hosty, wszystkie pociągnięte do `c3d664c` i z czystym audytem
`deploy.sh --check-only` (2026-07-31):

| Host | Adres | Commit | Konto delegowane | `sudo` |
|---|---|---|---|---|
| pve0 | 192.168.11.10 | `c3d664c` | — | jest |
| pve1 | 192.168.11.11 | `c3d664c` | — | jest |
| metropolis pve1 | 192.168.28.9 | `c3d664c` | `zfsbackup` | brak |
| metropolis pve2 | 192.168.28.8 | `c3d664c` | `zfsbackup` | brak |

Wersje programów w drzewie:

| Program | Wersja |
|---|---:|
| `snapsend.sh` | `v2.68` |
| `snapget.sh` | `v2.65` |
| `delsnaps.sh` | `v1.28` |
| `gen-cron.sh` | `v4.25` |
| `check-snap-age.sh` | `v2.0` |

`deploy.sh`, `zfs-backup.sh`, `zfs-quiesce-helper.sh`, `update-control.sh` i
`check-pool-capacity.sh` nie mają własnej stałej `VERSION` — identyfikuje je
commit.

### Stan grantu quiesce na hostach: ZEROWY

Na żadnym z czterech hostów nie ma dziś:

- `/usr/local/sbin/zfs-quiesce-helper`;
- `/etc/zfs-quiesce-allow/`;
- żadnej reguły `/etc/sudoers.d/zfs-quiesce-*`;
- żadnych pozostałości `*.zqg-new` / `*.zqg-bak`.

Na pve0 i pve1 (192.168.11.x) został **wyłącznie pakiet `sudo`**, zainstalowany
2026-07-31 o 14:35 i 15:45 przez testowe przebiegi `--allow-quiesce`. To jest
dokładnie stan opisany w REV-20260731-009 §5: pakiet zostaje, granta nie ma, i od
`ad5e745` kod mówi o tym wprost przy każdej takiej awarii.

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
wyłącznie stubowane — na produkcji przeszedł happy path. Nie wykonano też
snapshotu w oknie zamrożenia, więc spójność samego obrazu nadal nie jest
zmierzona.

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

**Przerwana aktualizacja** zostawia grant wyłączony, a kopia pod `.zqg-bak` jest
wtedy jedyną. Sweep rozróżnia: cel istnieje → kopia zbędna, usuń; celu brak →
przywróć i powiedz o tym. Czyli przerwanie jest fail-closed, a kolejne uruchomienie
samo je leczy.

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

Uruchomione lokalnie przy `c3d664c` (bez roota, bez ZFS, bez sieci):

| Pakiet | Wynik | Zakres |
|---|---|---|
| `impact` | 21/21 | rozwiązywanie grafu testowego + `--verify` na prawdziwym drzewie |
| `gencron` | 56/56 | parsowanie konfiguracji `gen-cron.sh`, golden + przypadki negatywne |
| `quiesce` | 46/46 | księgowanie `-q`: własność guesta, deduplikacja |
| `tune` | 48/48 | cache autotune `-A` |
| `statekey` | 16/16 | klucz stanu i jego kolizje |
| `selfupdate` | 28/28 (7 SKIP) | kontroler aktualizacji i rollbacku |
| `zfsbackup` | 72/72 | warstwa orkiestracji `zfs-backup.sh` |
| `quiescehelper` | 87/87 | granica uprzywilejowana helpera + transakcja grantu |
| `join` | 42/42 | walidacja paczki `--join`, granica zaufania |

Wymagają roota, ZFS albo drugiego hosta — **nieuruchamiane przy tym commicie**,
bo to środowisko ich nie ma. Ostatnie wykonanie odnotowane w odpowiedziach na
recenzje:

| Pakiet | Czego wymaga | Zakres |
|---|---|---|
| `snapsend` | root, zfs, mbuffer | silnik push/pull, semantyka flag |
| `delsnaps` | root, zfs | retencja, prefiksy, GFS |
| `scenarios` | root, zfs, mbuffer | wygenerowane linie crona uruchamiane dosłownie |
| `remote` | drugi host, ssh, zfs | kampania dwuhostowa, root i konto delegowane |

Siedem pozycji `SKIP` w `selfupdate` to przypadki wymagające `chattr +i`, którego
to środowisko nie obsługuje.

Wszystkie pakiety wymienione w `test/deps.conf` muszą występować w tej tabeli;
pilnuje tego `test/impact/run.sh`.

Zweryfikowane na żywo 2026-07-31: `sqlfreeze` na produkcyjnym vsql2 (VM 100),
reguła kropki w `sudoers.d` (visudo 1.9.5p2, z kontrolą negatywną), akceptacja
generowanej reguły sudoers przez prawdziwy `visudo`, `deploy.sh --check-only` na
czterech hostach w obu formach hosta.

## 6. Otwarte — i u kogo leży

### Czeka na werdykt recenzenta

- **REV-20260731-012 — kolejność commitu przy aktualizacji.** Finding przyjęty w
  całości: uzasadnienie „whitelista jest ograniczeniem" było moje i było błędne.
  Kolejność zmieniona na „najpierw wyłącz aktywną regułę", 6 nowych testów mierzy
  efektywną granicę uprawnień, nie pliki.
- **REV-20260731-011 §2 — spór.** Zakwestionowałem tezę, że ścieżka błędu
  `mkdir allow_dir` nie wywołuje rollbacku: wywołanie jest tam od `763767b`,
  dowód przez `git show 7dc4a98:deploy.sh`. Zgodziłem się warstwę niżej
  (`created_dir=0` zostawiał pusty katalog) i to naprawiłem w `5fec1f4`.
- **Commity `50fe6cf`, `776ee42`, `c3d664c`** powstały po ostatniej recenzji
  (`d0d8a89`) i nie były jeszcze recenzowane.

### Czeka na decyzję właściciela

- **Korelacja per przebieg dla SQL** (REV-010 §2): odczyt najwyższego
  `EventRecordID` przed freeze i tylko nowych zdarzeń po thaw, wewnątrz jednej
  operacji zdalnej `snapget -q`. To nowa powierzchnia uprzywilejowana.
- **`--require-engaged` / `verify-sql-quiesce`** (REV-010 §3): tryb fail-closed,
  ma wejść razem z pierwszym konsumentem, nie wcześniej.
- **`PAIRING-DESIGN.md` Wariant B** — nadal propozycja, nie kod.
- **Automatyczna instalacja draft-configu** bez przeglądu administratora —
  odłożona.

### Znane luki, nie planowane do zamknięcia teraz

- **Test odtworzenia vsql2.** Jedyna rzecz, która dowodzi, że snapshot się
  przywraca. Nie wykonany.
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
bieżący; historia decyzji żyje w `docs/reviews/` i `docs/reviews/responses/`.
