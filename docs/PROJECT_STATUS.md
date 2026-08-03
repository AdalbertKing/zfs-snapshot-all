# PROJECT_STATUS — faktyczny stan projektu

> **To jest dokument ŻYWY, nie protokół z jednego dnia.**
> Odświeżany przez implementera na końcu **każdego** etapu, zanim etap zostanie
> zgłoszony jako zrobiony. Jeżeli data poniżej jest starsza niż ostatni commit
> zmieniający zachowanie — dokument jest zepsuty i to jest defekt do zgłoszenia,
> nie drobiazg. Obowiązek jest zapisany w `CLAUDE.md` i przypomina o nim
> `./test/impact.sh` jako obowiązek ręczny `project-status`.

- Data odświeżenia: **2026-08-03** (po REV-034 w całości, po REV-033
  plasterku 2, po REV-035, po REV-036 w całości, i po ad hoc
  `--pause`/`--resume` poza kolejką recenzji, w tym przeróbka na tryb blokowy)
- Zweryfikowano przeciw: `f6f4ce3` **plus commit niosący ten dokument** —
  dokument nie może podać własnego SHA, więc podaje rodzica; to jest konwencja,
  nie niedopatrzenie
- Ostatnia zmiana zachowania produkcyjnego: **REV-20260803-036** —
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
  `docs/reviews/responses/REV-20260803-036.md`. Wcześniej `f6f4ce3` —
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
  `docs/reviews/responses/`.** REV-032 przeszedł pełen komplet suit **przed**
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

## 1. Co jest wdrożone, gdzie i w jakiej wersji

Cztery żywe hosty, wszystkie na `5ff1b0b` lub nowszym (godzinowy
`--self-update`; metropolis pve1 i pve2 pociągane bezpośrednio 2026-08-01, oba
checkouty — root i konto). `deploy.sh --check-only` czysty na metropolis pve1
2026-08-01, na pozostałych 2026-07-31.

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

Wysokopoziomowy przepływ ukrywa `pair`/`join`:

```
setup-server → add-client → seed → verify-endpoint → activate-client
             → status / test / migrate-profile / remove-client
```

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

**Limit pasma** `--bandwidth=N` jest per klient (bajty/s, `mbuffer -r`).

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
`lib-zfs-snap.sh`) przebiegnięte ponownie przy tym commicie:

| Pakiet | Wynik | Zakres |
|---|---|---|
| `impact` | 21/21 | rozwiązywanie grafu testowego + `--verify` na prawdziwym drzewie |
| `gencron` | 56/56 | parsowanie konfiguracji `gen-cron.sh`, golden + przypadki negatywne |
| `scope` | **34/34** | gramatyka pliku zakresu (REV-033 F2): sekcje `[dataset:]`, `include_parent`/`include_children`/`exclude`/`exclude_tree`, odmowy z numerem linii oraz decyzja „czy ten dataset jest w zakresie" |
| `cron` | **123/123** (bez zmiany liczby — nowe funkcje ćwiczone przez `pause`) | `lib-cron.sh` — jedyny pisarz crontaba: blok zastępowany w miejscu, wszystko poza nim bajt w bajt, markery zepsute odrzucane a nie naprawiane, `crontab(1)` zaślepiony (także tryb „przyjmuje zapis i przechowuje co innego"), zamek per-użytkownik z wymuszonym przeplotem dwóch procesów (REV-034 F2, +14), całościowy zapis `cron_replace_all` z odczytem zwrotnym (REV-034 F3, +9), jeden stały katalog blokad bez fallbacku per-caller (REV-035, +8, część SKIP na tej maszynie). Od REV-036 F5 biblioteka sama rozpoznaje zapauzowany kształt (`cron_fullcron_paused`/`cron_block_paused`) i odmawia przez `cron_paused_guard` w `cron_block_install_impl`/`cron_block_ensure_line_impl`/`cron_block_remove_impl` — ćwiczone przez `pause` (sekcje S/T), nie tu |
| `cron2conf` | 10/10 | odtwarzanie configu z crontaba — round-trip przez prawdziwy `gen-cron.sh`, przypadki negatywne/ostrzegawcze |
| `quiesce` | **161/161** | księgowanie `-q`: własność guesta, deduplikacja, trasa uprzywilejowana lokalnej ścieżki (+10) odmowa zamiast degradacji (+14, REV-023) **oraz okno zamrożenia jako termin (+15, REV-024)** |
| `tune` | 48/48 | cache autotune `-A` |
| `statekey` | 16/16 | klucz stanu i jego kolizje |
| `selfupdate` | 28/28 (7 SKIP) | kontroler aktualizacji i rollbacku |
| `zfsbackup` | **211/211** | warstwa orkiestracji `zfs-backup.sh` (+45 tego wieczoru: wykonywalność bloku, listy przecinkowe, uprawnienia i quiesce wyprowadzane z zadań; sekcja 25 przepisana pod `cron_replace_all`, REV-034 F3) |
| `quiescehelper` | **119/119** | granica uprzywilejowana helpera + transakcja grantu + **nadanie dla konta lokalnego (+14)** |
| `join` | **54/54** | walidacja paczki `--join`, granica zaufania; +12 dla `--commit-scope-check` (REV-033 slice 2) |
| `pause` | **74/74** | `deploy.sh --pause`/`--resume` na okno serwisowe (wymiana dysku, migracja VM). Domyślnie: zakomentowanie TYLKO ciała bloków tego pakietu (markery `lib-cron.sh`, jawny rejestr `PAUSE_KNOWN_BLOCKS`, obcy blok o tej samej gramatyce nietykany — REV-036 F4) w miejscu, wszystko inne w crontabie (roota i konta) chodzi dalej — jednym zapisem przez `cron_replace_all_impl`, nie po bloku (REV-036 F2). `--fullcron` przywraca dawne zachowanie: cały crontab zapisany i zastąpiony jednym placeholderem, stan zapisywany DURABLE przed zamianą crontaba (REV-036 F1) i porównywany bajt-po-bajcie przy resume (REV-036 F3). `--resume` sam rozpoznaje, w którym trybie dany user został zatrzymany; ręczna linia dopisana wewnątrz zapauzowanego bloku w oknie przeżywa resume, nie jest cicho gubiona. `lib-cron.sh` sam odmawia KAŻDEMU zwykłemu pisarzowi (nie tylko `deploy.sh`) nadpisania zapauzowanego kształtu (REV-036 F5) |

Wymagają roota, ZFS albo drugiego hosta. **Uruchomione 2026-08-01 na metropolis
pve1 przy `d8bb52a`** (i wcześniej przy `244ec0d` i `55d33a2`), bo `snapsend.sh` zmienił się
razem z biblioteką:

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

### Zamknięte przez recenzenta

- **REV-20260731-013 — odzyskiwanie po crashu: ZAMKNIĘTE** (REV-014). Sweep
  parkuje zaparkowaną regułę zamiast ją uzbrajać; recenzent uznał zachowanie za
  poprawnie fail-closed i przyjął, że testy mierzą efektywną granicę, a nie
  obecność plików.
- **Poprawka `sqlfreeze` (warunkowa notka): PRZYJĘTA** tą samą recenzją.
- **REV-20260731-012 — kolejność commitu: przyjęta** w REV-013.
- **Transakcja grantu wraz z odzyskiwaniem po crashu** jest przez recenzenta
  uznana za akceptowalną infrastrukturę dla **opcjonalnego** remote quiesce.

### Otwarte u implementera

- **REV-021 — zaimplementowane w `1edca10`, czeka na werdykt.** Instalacja nie
  może skasować zadań, które cel już wykonuje (`assert_target_block_not_clobbered`),
  a linie „porzucone" przez render konta trafiają do bloku ogólnohostowego
  **tylko** jeśli są rozpoznane jako ogólnohostowe — reszta zatrzymuje migrację
  z podaniem linii. Odpowiedź: `docs/reviews/responses/REV-20260801-021.md`.
- **REV-018/-019/-020 — zaimplementowane w `1d5a8c4`, czekają na werdykt.**
  Bramka duplikacji porównuje teraz **tożsamość zadań**, nie ścieżkę configu
  (`job_identity()` zdejmuje katalog skryptu i log, zostawia harmonogram,
  datasety, wzorzec, retencję, quiesce i progi). Doszedł czasownik
  `zfs-backup.sh migrate-to-account <konto> [--preflight] [--yes]` z pięcioma
  fazami REV-020 F3, a linie ogólnohostowe (digest) dostały własny blok
  `# BEGIN zfs-backup-host` w crontabie roota zamiast być luźną linią, której
  nikt nie jest właścicielem. Odpowiedzi: `docs/reviews/responses/REV-20260801-018.md`,
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

- **REV-20260801-021** (`1edca10`, `99ba1f5`) — instalacja nie może skasować
  zadań, które cel już wykonuje; tylko rozpoznane linie ogólnohostowe zostają
  w crontabie roota. Odpowiedź w `docs/reviews/responses/REV-20260801-021.md`.
- **REV-20260801-022 F1** (`32d6ed1`) — `--allow-quiesce` musi nazwać konto,
  które dostaje grant, i odmówić zamiast kończyć się zerem. Odmowa przeniesiona
  na czas argumentów, czyli mocniej niż wymagała recenzja. Odpowiedź w
  `docs/reviews/responses/REV-20260801-022.md`. **Nota produktowa recenzji
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
  `docs/reviews/responses/REV-20260801-023.md`. Piąta gałąź (tryb niepasujący)
  wykracza poza literę recenzji — zaznaczone tam wprost do ewentualnego
  odrzucenia.
- **REV-20260801-026** (`5ff1b0b`) — uprawnienia ZFS wyprowadzane z wyrenderowanych
  zadań, nie z typu sekcji; komunikat naprawczy z dokładną listą datasetów.
  Odpowiedź w `docs/reviews/responses/REV-20260801-026.md`.
- **REV-20260801-027** — to samo o jeden poziom wyżej: quiesce sprawdzany
  **per zadanie** przez prawdziwego helpera, jako konto, zamiast jednego
  hostowego „czy konto dosięga helpera". Zweryfikowane na żywo na wszystkich
  czterech hostach. Odpowiedź w `docs/reviews/responses/REV-20260801-027.md`.
- **REV-20260801-024** (`be1cfe7` + `d8bb52a`) — okno zamrożenia jako termin, nie
  kolejność. Wszystkie pięć wymaganych zachowań, zmierzone na żywo: 18 s → 1 s.
  Odpowiedź w `docs/reviews/responses/REV-20260801-024.md`. Do zważenia przez
  recenzenta: budżet 5 s oznacza, że host z kilkoma wolno mrożącymi się gośćmi
  Windows w **jednym** zadaniu legalnie go przekroczy i to zadanie padnie —
  kierunek fail-closed, ale zmiana zachowania dla konfiguracji, której nikt
  jeszcze nie próbował.
- **REV-20260801-025** (`7564f8e` + `c7ce8da`) — granica quiesce'u ma objąć
  **każdą pulę** i **ścieżkę zdalną**. Odpowiedź w
  `docs/reviews/responses/REV-20260801-025.md`, **napisana z opóźnieniem i tak
  właśnie opisana**: F1 zostało bez pliku odpowiedzi, więc recenzent nie miał
  jak odróżnić „niesione" od „nieprzeczytane" i zapytał drugi raz jako REV-029.
- **REV-20260802-028** (`90a06c8`) — `--add-quiesce`: grant wyłącznie
  dokładający, idempotentny, fail-closed przy nieczytelnej whiteliście;
  `--allow-quiesce` nadal nadpisuje, bo dla **zapisu** to jest poprawne.
  Odpowiedź w `docs/reviews/responses/REV-20260802-028.md`.
- **REV-20260802-029** (`c7ce8da`) — powtórka REV-025 F1: granica sprawdzana
  przed **każdą** pulą, na obu ścieżkach. Odpowiedź w
  `docs/reviews/responses/REV-20260802-029.md`.
- **REV-20260802-030** (`9fbf1df`) — niekompletny zestaw quiesce jest
  **usuwany**, nie tłumaczony: rejestr tego, co przebieg utworzył, trzy wyjścia
  (komplet / nic nie zatwierdzono / **ROLLBACK INCOMPLETE**, kod 7, z nazwą
  każdego ocalałego snapshotu). Odpowiedź w
  `docs/reviews/responses/REV-20260802-030.md`.
- **REV-20260802-031** (`3d4c13f`) — sam raport wycofania nie może zawieść
  fail-open. Drugi plik tymczasowy **usunięty**, nie obsłużony; nieudany zapis
  rejestru kończy się kodem 7 z nazwą snapshotu. Odpowiedź w
  `docs/reviews/responses/REV-20260802-031.md`.
- **REV-20260802-032** (`700d045`, `52ec5e6`) — nieudany zapis rejestru musiał
  rozliczyć **cały** zestaw, nie tylko nazwę, która akurat nie weszła. Rozwiązane
  **inaczej niż sugerowała recenzja**: nie drugim rejestrem na to, czego pierwszy
  nie pomieścił, tylko usunięciem pliku — rejestr jest tablicą, jak od zawsze na
  ścieżce lokalnej, więc klasa błędu znika zamiast być obsługiwana. Powód
  odstępstwa jest zmierzony i opisany w odpowiedzi: każda przenośna próba
  zepsucia pliku *między pulami* kasowała też **zapis wcześniejszej puli**.
  Odpowiedź w `docs/reviews/responses/REV-20260802-032.md`. **Do zważenia przez
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
  Odpowiedź: `docs/reviews/responses/REV-20260802-034.md`.
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
  `crontab(1)`) na wszystkich 4: **73/74** wszędzie — jeden powtarzalny,
  zdiagnozowany fałszywy fail (sekcja G zakłada brak konta delegowanego,
  a każdy z tych hostów je ma; `detect_delegated_account()` skanuje
  prawdziwy `/home/*`, czego ta rodzina testów nie stubuje) — zgłoszone jako
  osobne zadanie, nie naprawione w tym passie. Prawdziwy cykl
  `--pause`/`--resume` na żywym crontabie **nie wykonany** — klasyfikator
  bezpieczeństwa odmówił (słusznie: to akcja zatrzymująca prawdziwe backupy,
  wymaga obecności właściciela, nie bezobsługowego zadania). `sudo
  ./test/scenarios/run.sh` (wymaga roota i puli ZFS) — nie uruchomiony.
  Odpowiedź: `docs/reviews/responses/REV-20260803-036.md`.
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
  Odpowiedź: `docs/reviews/responses/REV-20260803-035.md`.
- **REV-20260802-033** — recenzja **projektowa**, nie defektowa: uproszczony
  enrolment ma odkrywać dane **na źródle**, trzymać jeden edytowalny plik
  zakresu i odróżniać endpoint od trasy. Recenzja wprost zabrania
  implementowania czegokolwiek przed odpowiedzią. Odpowiedź w
  `docs/reviews/responses/REV-20260802-033.md`: **wszystkie pięć findingów
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
  Odpowiedź: `docs/reviews/responses/REV-20260802-033.md` (addendum
  2026-08-03).
- **REV-20260731-011 §2 — spór.** Zakwestionowałem tezę, że ścieżka błędu
  `mkdir allow_dir` nie wywołuje rollbacku: wywołanie jest tam od `763767b`,
  dowód przez `git show 7dc4a98:deploy.sh`. Zgodziłem się warstwę niżej
  (`created_dir=0` zostawiał pusty katalog) i to naprawiłem w `5fec1f4`.
  Recenzent nie odniósł się do tego wprost w późniejszych recenzjach.

### Czeka na decyzję właściciela

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
bieżący; historia decyzji żyje w `docs/reviews/` i `docs/reviews/responses/`.
