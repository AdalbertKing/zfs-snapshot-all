# Ściąga dla recenzenta: co weszło od 2026-10-05 i od czego zacząć

Przygotował: implementer (sesja Claude), na polecenie właściciela, 2026-10-16. Stan `main` = `a141553e`.

## 0. Gdzie jesteśmy

- **Ostatnia aktywność recenzenta: 2026-10-05 00:07** (`0e9446ee`, „review: open REV-20261004-146 endpoint history”,
  PR #452). Od tego czasu żadnego werdyktu ani nowego REV.
- **REV-20261004-146: `IMPLEMENTED -> Reviewer`**, SHA `7fe07cab`, czeka od 2026-10-06 (`responses/REV-20261004-146.md`).
  Pozostałe REV do 145 włącznie: `CLOSED`.
- **Od tamtej chwili do `main` weszło 107 PR-ów (#451–#558).** #451 to implementacja REV-146, #452 to twój PR
  otwierający REV-146; **pozostałe 105 weszły poza REV.** Prowadził właściciel rundami testów
  (uwagi U/K/W/X/P) i poleceniami w czacie. Każdy PR przeszedł CI i bramki `impact.sh --verify` (status digest,
  zamrożenie, graf), a stan opisuje `docs/PROJECT_STATUS.md` (wpisy od góry są najnowsze).
- **Produkcja (Metropolis pve1/pve2) i cały lab biegną na tym kodzie** -- godzinna samoaktualizacja ściąga `main`.

Lista wszystkich PR-ów z datą, tytułem i plikami kodu jest w §8. Poniżej kolejność, w jakiej proponuję je przejrzeć:
od największego ryzyka do najmniejszego.

## 1. NAJPIERW: zamrożone silniki zmienione bez recenzji wstępnej

`ENGINE-FREEZE.md` wymaga recenzji wstępnej i znacznika `authorizes-frozen` od recenzenta. **Te zmiany zrobiono na
bezpośrednie polecenie właściciela** (cytaty w `ENGINE-FREEZE.md`, wpisy 2026-10-06 / -08 / -12, ~819–966),
**bez recenzji wstępnej i bez znacznika recenzenta.** Każda ma testy w suitach silników i była sprawdzona na labie,
ale nikt poza implementerem nie czytał diffu.

Pełny diff silników od ostatniej recenzji:

```bash
git diff 7fe07cab a141553e -- snapsend.sh snapget.sh lib-zfs-snap.sh
```

(354 linie dodane, 23 usunięte; `delsnaps.sh` i `check-snap-age.sh` bez zmian.)

| PR | zmiana | pliki silnika | wpis ENGINE-FREEZE |
|---|---|---|---|
| #453 | `progress_done` zastępuje zakończony koniec rekordu postępu | lib-zfs-snap.sh (+16/−2) | 2026-10-06 ~819 |
| #455 | bieg pominięty przez blokadę (flock) -> kod 75 i ostrzeżenie, nie 0 | snapsend.sh, snapget.sh (+18/−4) | 2026-10-06 ~837 |
| #460 | **`snapget -M`: relacja synchro jako lustro źródła** (kasuje na celu to, czego źródło nie ma) | snapget.sh (+90/−3) | 2026-10-06 ~863 |
| #463 | replika na `snapget -M` (lustro nośnika) | snapget.sh (+7/−1) | 2026-10-06 ~889 |
| #480 | **P-0: kopia backupu podąża za źródłem** -- jedna polityka rozjazdu w obu silnikach (`recv -F` przy lądowaniu kopii, odmowa przy zapisie po wspólnej migawce na celu dokładnym) | lib-zfs-snap.sh, snapget.sh, snapsend.sh (+133/−6) | 2026-10-08 ~908 |
| #481 | poprawka opisu P-0 / synchro z GUI | snapget.sh (+4/−3) | -- |
| #482 | **P-0 dla lustra:** `-M` też podąża za źródłem, gdy ścieżka nie jest dyskiem działającego gościa | snapget.sh (+18/−5) | 2026-10-08 ~943 |
| #510 | **W19:** cel pod zaszyfrowanym rodzicem; **W14:** cichy wpis przy zdjęciu migawek repliki | lib-zfs-snap.sh, snapget.sh, snapsend.sh (+86/−17) | 2026-10-12 ~962 |

**Proszę zacząć od zmian, przy których silnik sam niszczy dane na celu:** #460 (lustro `-M` kasuje na celu migawki,
których źródło nie ma), #480 i #482 (P-0, `recv -F`). Kontrakt P-0 i jego testy: `test/snapsend` P5–P10, opis w PROJECT_STATUS (szukać „P-0”).

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #510 / W19 i W14.**
Dokładny zakres `71b51681f7d576db47fad7b70598f35efea034a4..bb509c2ebacf2db2bdc93f8f6855d5a311f5d8de`,
zmiana produkcyjna `ed97b9bdc83fa4cf284e68fb6685de20f98c3b84`,
merge `bfbc3b5d20c937b60c9532469e237f194603e9aa`. W19 poprawnie pozostawia
nieistniejący liść zaszyfrowanego rodzica dla `zfs receive`; błąd odczytu
szyfrowania zachowuje dawną ścieżkę i nie daje fałszywego sukcesu ani nowego
uprawnienia do kasowania. W14 nie zmienia decyzji `receive -F`, tylko obniża
głośność wpisu przy `written@base=0`, niepustej liście i wyłącznie migawkach
`replica_*`; obce, zapisane i puste przypadki pozostają głośne.

Niezależne kontrole na `main` `ba2b561dd04f47c914c08d2e64385b07dae1b880`:
W14 4/4, sztuczny ZFS dla W19 (rodzic zaszyfrowany i kontrola niezaszyfrowana),
negatywna kontrola dokładnej bazy bez obu helperów, twins 94/94, eval-free
16/16, składnia, `diff --check` i `impact --verify` — PASS. CI dokładnego heada:
run `38242689996` — success. Ręczny dowód na jednorazowych pulach `pve9b`
obejmował pierwszy i przyrostowy push oraz pierwszy pull; recenzent nie
powtarzał operacji na żywym hoście. Brak nowego REV.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #463 / replika na snapget -M.**
Dokładna baza `9fb9a7afd2904c8ac58d1a7e989b1ed19e49e428`, head
`91954aafa0ca1305d86669ab5c4159ec768f9674`, merge
`76ee2e94f7da0eedcee593bd8c5f11293cfab75f`.
Wersja współczesna: `7ff2b0bd1d11ab865a03100023b0606c2a3fbc0e`. Zmiana `snapsend -m` na
`snapget -m -M` zachowuje bookmark po tym samym celu i identyfikatorze
(wspólna funkcja `bookmark_target_tag`); lustro raportuje usuwanie i
przeszkody na poziomie 0. Aktualna bramka rozróżnia identyfikatory GUID
i import własny od zastanego; poprawki #741/#742 należy liczyć oddzielnie.
Próby CI main `40112247542`: mediagate 160/0, twins 94/0, cron 232/0,
gencron 123/0, składnia i graf PASS. PR-head `37495811929`: SUCCESS.
Historyczne `cron2conf` usunięto świadomie w X27 S4, ale dokładny head
odtworzono w worktree: 31/0; ta sama suita z parserem dokładnej bazy przegrywa
trzy nowe kształty repliki. Dawna liczba czterech porażek z opisu PR nie jest
reprodukowalna. Historyczny `twins` daje dziś 93/94 wyłącznie przez termin
portowania `process_dataset`, który upłynął 2026-10-19; port jest ukończony na
bieżącym main. Live USB/pve9 opisane przez implementera, niepowtórzone przez
recenzenta. Bez nowego findingu/REV. Następny zakres: **#453/#455** — końcowy
rekord postępu i rc 75/raportowanie pominięcia przez blokadę. #480/#482 są już
objęte REV-151 i jego zatwierdzoną kontynuacją.

Zakres PR #463 zamknięto powyższym audytem. Granicy kasowania lustra z PR #460 / REV-150
nie otwierać bez nowego diffu lub dowodu.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #453 / #455.** PR #453:
`45d0dc0c54d8f24df776743dbdcafd9ddde8c840..27072f9bedf39cf9fdb2fffea651eb9ec6f66935`,
produkcja `e03c2df2372e54191cec9c389b3dfe83dfa0e871`, merge
`9de180bf0213e3b3c3ee14eee64181d9f2d5e09e`. `progress_done` zastępuje
bieżący albo już zakończony terminal rekordu i leczy dawną sklejoną końcówkę;
nieznany kształt zostawia bez zmian, a rekord nie steruje transferem. Dokładny
head ma dziś twins 82/83 tylko przez termin portowania `process_dataset`, który
upłynął 2026-10-19; biblioteka z dokładnej bazy dodaje właściwą drugą porażkę
(81/83). CI heada `37450082594` było zielone przed terminem.

PR #455: `2a5c8201afc67628fa6b79c067984e2c304d8277..2d433ca7955f97c2f944c4c77d3a67093ea6eaa0`,
produkcja `b11cd9e1420edf62ff52a95f873c79ee1a9080a0`, merge
`2daddf61d3171a2613906df75c70c964da4a4e84`. Oba silniki zwracają 75 po
utracie blokady, zachowując tekst i `skipped_lock`; `zfs-job` zapisuje ten rc i
woła wyłącznie warning, podczas gdy rc 1 nadal woła failure. Dokładny head:
pairpause 22/22, cron 146/146. Dokładna baza z testami heada: 20/22 (po jednej
porażce na silnik) i 145/146 (złe mapowanie notyfikacji). Bieżące drzewo:
twins 94/94, pairpause 22/22, cron 232/232; oba `diff --check` przechodzą, CI
heada `37452537070` jest zielone. Live pve10 autora potwierdziło drugą równoległą
kopię jako rc 75 i jeden WARN bez ALERT; recenzent nie powtarzał operacji na
żywym hoście. Brak nowego REV.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #465 / REV-174.** Generator
poprawnie wybiera najdrobniejszy nośnik, chroni pozostałe rodziny i repliki oraz
odmawia zdalnego zakresu. Potwierdzono jednak nowy P1 w wyjątku instalatora:
normalizacja U4 usuwa wszystkie `-P`, więc równoczesne
`vzdump:2 -> vzdump:0` jest niewidoczne i destrukcyjna propozycja przechodzi.
Zwykła zmiana tej ochrony bez U4 jest poprawnie odmawiana. Dokładny head ma
cron 165/165, cron2conf 35/35, passivepick 12/12 i mirrorguard 8/8; kontrole na
bazie przegrywają odpowiednio 7, 4, 1 i 1 przypadek, ale nie obejmują
krzyżowej zmiany `-P`. REV-20261024-174 zawiera bezpieczny reproducer na
produkcyjnej funkcji strażnika. Następny niezależny zakres: PR #469 — rozrzut
harmonogramu źródłowego prune; odpowiedź na REV-174 ma zawsze pierwszeństwo.

Uwaga do terminologii: wpis 2026-10-06 w `ENGINE-FREEZE.md` (~819) nazywa zmianę „PRE-AUTHORISED by the owner”, choć
dokument (~1016–1035) mówi, że autoryzacja zamrożonego pliku należy do recenzenta. Żaden z wpisów 2026-10-06/-08/-12
nie ma znacznika `authorizes-frozen`.

Znane, zgłoszone, **nie naprawione** (silniki zamrożone): `docs/project/ENGINE-ALREADY-EXISTS-SKIP-2026-10-15.md` --
skrót „Snapshot already exists in target – skipping” działa przed P-0.

## 2. Wady w rzeczach, które recenzent już zamknął (dowód zamknięcia okazał się pusty)

Każda z tych wad siedziała w kodzie, który przeszedł REV i został `CLOSED` albo był opisany jako zamknięty (F23). Wyszły na żywo w październiku. Proszę
o ocenę, czy trzeba wrócić do zamkniętych REV albo czegoś w procesie (R1 z error logu: „udowodnij, że straż da się
osiągnąć”).

| PR | wada | od kiedy | zamknięte w |
|---|---|---|---|
| #557 (P8) | mapa GUID kontroli po odzysku (`restore_one`) -- awk z dosłownym znakiem nowej linii w `printf`, mapa zawsze pusta, kontrola sprawdzała tylko NAZWĘ migawki | 2026-08-31 | REV-20260831-129 -- **uwaga: nagłówek `verdict: APPROVED`, ale treść „CHANGES REQUIRED — P1 BLOCKING” i brak sekcji późniejszej akceptacji; ledger pokazuje CLOSED wyłącznie z nagłówka. Do sprawdzenia, czy to zamknięcie było zamierzone** |
| #551 | `coverage_conflicts`: `die` z `record_load` w podpowłoce zabijał cały program (`die_arm_fatal`), komunikat w `2>/dev/null` -- odmowa „nieczytelny rekord” była nieosiągalna, wywołujący kończył cicho rc 1 (dotyczy też straży nakładania) | od wprowadzenia `die_arm_fatal` | REV-20260809-084 |
| #547 | bramka pary odrzucała zakres z wieloma datasetami (zła biała lista znaków), pusty zakres wyłączał bezpiecznik po stronie kolektora -> `replace` **zniszczył korzeń zakresu na labie** | bezpiecznik od 2026-08-28 | F23 kampanii labu (`08ab57cd`), bez osobnego REV -- bezpiecznik był martwy dla każdego zakresu z ≥ 2 datasetami |
| #541 | odzysk relacji lokalnej do wcześniejszego punktu zgłaszał sukces i nic nie robił | -- | restore lokalny |
| #539 | `restore <relacja lokalna>` kończył dyspozytor rc 1 bez słowa | -- | restore lokalny |

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #557 / REV-20260831-129.**
Zamknięcie było zamierzone i formalnie spójne: commit akceptacji
`2d379051308f946fe618637830ea5e9b37923638` wskazuje implementację
`8c5204919f366371810535417b18f3592e6bbfd9`, a closure i ledger wskazują tę
samą akceptację. Dowód akceptacji był jednak niewystarczający: test 9/9
omijał produkcyjne budowanie mapy w `restore_one`; na zatwierdzonym SHA sam
program awk kończy się `runaway string constant` (rc 2). PR #557 naprawił
produkcję w `5b9ae11777c980e74a269b91fc99cc793208d4e7` i dodał test wyniku mapy oraz
jej użycia przez `restore_one`. Na bieżącym `main` testy `offpoint` są 9/9,
pełny `test/restore` 335/335, a historyczne CI dokładnego head PR #557
(run 38810678111) jest zielone. REV-129 pozostaje CLOSED: nie ma obecnej
reprodukcji błędu ani nowego kodu przeczącego poprawce; luka dotyczy jakości
historycznego dowodu i została zapisana w `REVIEWER-CHECKPOINT.md`.


**Rozstrzygnięcie recenzenta 2026-10-24 — PR #551 / REV-20260809-084.**
Wpis backlogu poprawnie wskazał późniejszą regresję osiągalności dowodu:
`die_arm_fatal` powodował, że `record_load` w podpowłoce kończył rodzica zanim
`coverage_conflicts` mogło zbudować nazwaną odmowę. Negatywna kontrola na bazie
PR #551 `b9b1e5c58f2f6e854f10e18abe6b99399f676b18` kończy się rc 1 i pustym
wyjściem. Commit `bb2ec7dc02e954e3122117f8a3738a2a3ed7dd72` dodał
`die_confine_to_subshell`; na bieżącym `main` ten sam przypadek zwraca rc 1,
drukuje fail-closed odmowę i dokładną ścieżkę złego rekordu. Dwie właściwe
asercje `test/restoregrant` przechodzą, `impact --verify` przechodzi, a CI
dokładnego head PR #551 (run 38759223428) jest zielone. REV-084 pozostaje
CLOSED: bieżąca własność bezpieczeństwa jest spełniona i nie ma nowego kodu
ani dowodu, który uzasadniałby ponowne otwarcie.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #547 / F23.**
F23 wszedł w `08ab57cdd25f257d28f369eaf9f4399358872b3f` bez osobnego REV,
approval ani closure. Jego opis błędnie uznał pusty zakres wyłączający straż za
bezpieczny, a commit nie dodał testu. Poprawiona aparatura PR #547 uruchomiona
przeciw dokładnej bazie `f7478b700fa294c63fd17dbf31b8bc56ff054ff8`
odtwarza oba ogniwa: bramka nie zgłasza listy wielu datasetów, a zdalny
`replace` z pustym zakresem dochodzi do silnika. Commit
`77e755e966b2796e2e50bd14385f5b47f3c5a547` poprawił białą listę i dodał
odmowę pustego zakresu przed silnikiem; późniejsze #548 rozróżniło korzeń od
dziecka, a opublikowany audyt #550 potwierdził bezpieczne odświeżanie
zainstalowanej bramki. Na bieżącym `main`
`6146dbab2d34296d1b195ec233ac56c6753225e6` wszystkie pięć właściwych asercji
przechodzi z pustym zapisem wywołań silnika, pairgate ma 92/92, restore 335/335,
`impact --verify` przechodzi, a CI dokładnego head PR #547 (run 38726889526)
jest zielone. Nie otwarto REV: luka historycznego dowodu jest naprawiona w
bieżącym kodzie, a dla F23 nie istnieje review, które można ponownie otworzyć.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #539 i PR #541.** Oba stare
zgłoszenia odtworzono na dokładnych bazach i oba są naprawione w bieżącym
kodzie. Dla #539 publiczne `restore rdl --plan` na
`ebb1fcf42eb88a8bda5c210e8210fb612db330e4` zwraca rc 1 i zero bajtów; na
bieżącym main zwraca rc 0 oraz plan tylko do odczytu. Dla #541 poprawiony test
uruchomiony na `616b6716ca90a918fc64850b11bc9e58152f844b` wykrywa brak rollbacku,
fałszywy sukces z nowszą migawką i brak odmowy bez przypiętej wspólnej bazy;
pięć odpowiadających asercji przechodzi obecnie. `test/restore` ma 335/335,
`test/deadcode` 7/7, właściwe asercje `localbackup` i `restoregrant` przechodzą,
oba wybory `impact` oraz `impact --verify` są zielone, a CI dokładnych headów
PR-ów przeszło (run 38701660631 i 38710218351). Bieżąca implementacja #541
ogranicza rollback do głębokości silnika i datasetów mających odpowiednik,
odmawia bez jednoznacznej bazy oraz po rc 0 mierzy GUID, najnowszą migawkę i
`referenced`. Nie otwarto REV: nie ma obecnej reprodukcji błędu ani nowego kodu
przeczącego poprawkom. Następny zakres recenzji: poszerzona delegacja odzysku
w PR #553.

## 3. Uprawnienia, zgody, operacje niszczące

Kolejność: odzysk (najwięcej nowych uprawnień), potem wdrożenie.

- **Odzysk ze zgodą celu** -- seria z kampanii odzysku 2026-10-15:
  - #545: potwierdzenie nadpisania („zawsze z potwierdzeniem, chyba że `--yes`”), klucz nośnika (`--key-file` /
    pytanie), droga „usuń + obok”;
  - #544, #546: `--at/--snapshot` w `--from-copy --overwrite`, `--with-history`;
  - #547, #548, #549: korzeń zakresu (bramka zgłasza listę, pusty zakres odmawia `replace`, zniknięty korzeń ->
    odmowa z naprawą; `--allow-restore` przy niezmienionej zgodzie nakłada delegację ponownie);
  - **#551:** `--allow-restore` **pauzuje relacje CELU** piszące do zakresu (`PAUSED_BY_GRANT`), `--deny-restore`
    wznawia tylko je, a gdy cofnięcie delegacji się nie udało -- nie wznawia niczego (rc 1);
  - **#553: zgoda POSZERZA delegację**: tworzy i deleguje `<pula>/restore` na celu (prawa zakresu + `mount`), żeby
    działał odzysk „obok”. **To nowa powierzchnia uprawnień -- proszę o ocenę.**
- **#550: bramka pary aktualizuje się sama** z pakietem (faza 7a `deploy.sh`). Pierwsza aktualizacja po scaleniu
  podmieniła bramkę na produkcji pve1/pve2 (sprawdzone, md5 = checkout).
- #474: `deploy.sh --leave` kończy procesy konta przed `userdel`.
- #467, #515: `delete-relation --destroy-copies` po seedzie bez aktywacji; replika w configu zatrzymuje blok crona.
- #485: `edit-config` (`crontab -e` dla configu), polecenie `/usr/local/bin/zfs-backup`.
- Szyfrowanie: #509 / #511 (zaszyfrowane źródło i replika wysyłane raw `-w`), #519 (zaszyfrowany nośnik repliki,
  klucz), #489 (bramka nośnika: pasywna replika zawsze uruchamia kopię).
- #542: kolizja dwóch relacji na jednym datasecie -- odmowa w obrębie hosta, ostrzeżenie przy kolektorze zdalnym.

**Rozstrzygnięcie recenzenta 2026-10-24 — PR #553 / REV-20261023-170.**
Ostrzeżenie backlogu było zasadne i zostało już obsłużone formalnym review.
Dokładny head #553 `30710f595b475a68c383a552d27c3e03b9a38641`
reprodukuje odebranie wspólnego `<pool>/restore` pierwszemu z dwóch aktywnych
grantów tego samego konta (**5/5 PASS reprodukcji**) oraz po zmianie konta w
manifeście cofa niewłaściwy tuple (**3 PASS / 3 FAIL**). REV-170 objął oba
kryteria, współbieżne `deny`, awarię i retry właściciela locka, niejednoznaczny
stary rekord oraz izolację kont i pul. Po dwóch odrzuconych implementacjach
zatwierdzono `e6b0be67f7060b7d427c952c047929bcaf37a0bc` i osobno zamknięto review.
Na bieżącym main reproducer wspólnego namespace ma 4 PASS / 1 oczekiwany FAIL
(uprawnienie prawidłowo zostaje dla drugiego właściciela), account-drift ma
6/6 PASS, właściwe testy `restoregrant` przechodzą, `restore` ma 335/335,
`deadcode` 7/7, a `impact --verify` jest zielone. Uprawnienie ogranicza się do
`receive,rollback,create,canmount,mountpoint,mount`; ostatni właściciel odbiera
je przed wznowieniem writerów, a namespace i odzyskane dane pozostają. Nie
otwarto nowego REV; REV-170 pozostaje CLOSED.

## 4. Zmiana modelu configu (X27) -- duża zmiana semantyki generatora

Etapy S1–S4 zrobione 2026-10-14 (PROJECT_STATUS); zamknięcie etapu ogłosił właściciel w czacie, w drzewie nie ma
osobnego zapisu zamknięcia. Relacja jest teraz blokiem `[relation:NAZWA]` w configu i jest **jedynym**
źródłem prawdy; ukryte szablony relacji i ich uzgadnianie usunięte; `migrate-profile`, `migrate-config`,
`cron2conf`, `clean-templates` usunięte.

- #521 → #525: config wygrywa z ukrytym szablonem; `show-tiers` / `set-tiers`; usunięcie uzgadniania;
- #527, #528, #529: „Użyj szablonu” we własne sekcje relacji, `set-tiers` dzieli sekcję wspólną;
- **#531, #533, #534, #535, #536: X27 A, S1–S4** -- `gen-cron` czyta `[relation:]`, `side = target|source`,
  czasowniki na bloku, sprzątanie;
- #537, #538: pola silnika (history, compression, cipher, autotune, raw) przeżywają przebudowę bloku.

Ryzyko: każdy kolektor na produkcji przeszedł na nowy odczyt configu. Proszę sprawdzić zgodność wstecz dla configów
sprzed X27 (`jobs.<host>.conf` bez bloków `[relation:]` -- flota produkcyjna nie ma rekordów relacji).

**Rozstrzygnięcie recenzenta 2026-10-24 — X27 / PR #531, #533–#536.**
Ostrzeżenie łączyło dwa różne kontrakty. Ręczny config sprzed X27, z
`[template:]` i `use_template`, nadal jest prawidłowym wejściem generatora:
produkcyjny fixture bez `[relation:]` renderuje się na bieżącym main (rc 0), a
pary stary/nowy dla relacji lokalnej i zdalnej dają ten sam cron. `test/run.sh`
ma 123/123, w tym negatywne kontrole niepełnych i mieszanych bloków. Natomiast
czasowniki modyfikujące nazwaną relację świadomie wymagają `[relation:NAZWA]` i
odmawiają staremu kształtowi bez zapisu, podając odtworzenie z profilu. To nie
jest brak migracji: właściciel 2026-10-14 zdecydował „bez zgodności wstecz” dla
automatycznej konwersji, po migracji labu host po hoście, i kazał usunąć
`migrate-config` oraz `cron2conf`; istniejący produkcyjny blok crona działa do
jawnej przebudowy. Przywrócenie tych narzędzi rozszerzałoby ustalony zakres 1.0.
Dokładne heady #531/#533/#534/#535/#536 (`e2cf0356…`, `37c94dd…`,
`cf210ace…`, `014066df…`, `133fc90a…`) mają zielone CI. Nie otwarto REV.

## 5. Nowe funkcje wsadu (poza GUI)

- **Lustro synchro**: #460, #461, #462 (silnik w §1), #481.
- **Replika na nośnik**: #463, #471 (on-insert), #477, #479 (ostrzeżenie o starej kopii), #488 (pasywna), #491
  (`prepare-media`), #493, #504 (dyski po ID), #508 (W18 `keep` = własna retencja nośnika), #516, #517
  (`replica-restart`).
- **Relacja lokalna**: #490 (L1 `local-backup --name`), #492 (L2), #506, #512 (szablony źródła `__lsrc_`), #536
  („Same migawki” = `local-backup --target=''`).
- **Zmiana relacji bez usuwania**: #470 (`edit-relation`), #476 (`add-source`), #483, #508 (W16 `set-transfer`).
- Monitoring / zadania: #458, #465 (obce migawki cięte jak własne), #469 (prune źródła rozrzucony), #514
  (`zfs-job` -- ręczne uruchomienie z prawdziwym kodem).
- Parowanie: #459 (jedna relacja na parę hostów; `--grant-remotely`), #468. (#451 = implementacja REV-146, §8 pkt 1.)
- Odzysk do GUI: #552 (`restore --plan --json`, `copy_exists`).

**Rozstrzygnięcie recenzenta 2026-10-24 — retencja źródłowa GFS i round-trip
`[relation:]`.** PR #610 (`3a99ff48…` → `b97e0be8…`, merge `03888a6c…`)
naprawił dziedziczenie `gfs=yes` po stronie źródła; kontrola na bazie odtwarza
brak `-G`, a bieżący blok relacji emituje `-G` tylko dla źródła i pozostawia
lądowisko celu płaskie. To było już niezależnie zapisane w nocie audytowej
REV-152. PR #629 (`998d1b2b…` → `8c9e435f…`) ujawnił w tej samej kampanii
błąd odtwarzania znaków ucieczki; właściwy REV-168 został naprawiony przez
`6413f161b9fd3f1f3830664a94275c2253e14418`, zatwierdzony i zamknięty.
Świeże kontrole: generator 123/123, export/import 79/79, reproducer REV-168
4/4, `impact --verify` zielone. Brak nowego kodu lub dowodu uzasadniającego
ponowne otwarcie; nie otwarto nowego REV.

## 6. GUI (najmniejsze ryzyko dla danych)

Okna whiptail / curses. Logika jest w czasownikach z §3–5, GUI składa polecenia.

- Rundy testów właściciela 10-08/10-09: #464, #473, #475, #478, #484, #486, #487, #494–#503, #506.
- 10-11/12: #507, #508; 10-13/14: #518, #520, #526, #530; X12 drzewo z kratkami #540.
- **Okna „Przywróć”** (2026-10-15): #554 (z relacji), #555 (z dysku), #556 (P1–P6), #557 (P7: granica `--at`).
  Właściciel testował w PuTTY #554, #555 i #556 (przed P7/P8); poprawek z #557 nie testował ponownie -- runda „na
  miejsce” z odpowiedzią „t” poszła na wersji SPRZED P7. Znana luka: `--with-history` w formie relacyjnej jest
  przyjmowany i po cichu pomijany (PROJECT_STATUS, wpis C2a).

## 7. Dokumenty i proces

- #452 -- twój PR (REV-146).
- #454, #456, #457 -- wpisy statusu; #472 -- `CLAUDE.md` (rozdział pracy na tańsze modele).
- **#558 -- czeka na ciebie:** `docs/project/ENGINE-REMOTE-SNAPSHOT-ONLY-2026-10-16.md`, **prośba o recenzję wstępną
  zmiany `snapget.sh`** (opcja `-s`: migawka na źródle zdalnym bez transferu) dla projektu „jeden kolektor + pvesr”
  (`DESIGN-JEDEN-KOLEKTOR-PVESR-2026-10-16.md`). **Lab tego projektu chodzi na produkcyjnym klastrze Metropolis**
  (testowy CT 990, linie `# ZSA-LAB-PVESR`): `LAB-METROPOLIS-PVESR-PLAN-2026-10-16.md`.

## 8. Proponowana kolejność pracy

1. REV-146 (czeka najdłużej, mały).
2. §1 silniki: najpierw #460 (lustro), #480 + #482 (P-0), potem #510, reszta. `ENGINE-FREEZE.md` nie przewiduje
   znacznika `authorizes-frozen` wydanego po fakcie (~1016–1035) -- jak zapisać werdykt dla zmian już wdrożonych,
   decyduje recenzent.
3. §2 pięć wad w zamkniętych REV -- decyzja, czy otwierać ponownie 084 / 129 (z jej niespójnym zamknięciem) i F23.
4. §3 uprawnienia, zwłaszcza #553 (poszerzona delegacja) i #551 (pauza celu), #550 (bramka sama się aktualizuje).
5. §4 X27 -- zgodność wstecz configów floty.
6. #558 -- recenzja wstępna `snapget -s` (blokuje dalszą pracę nad „jednym kolektorem”).
7. §5–6 w miarę czasu; GUI można próbkować.

Szczegóły każdego etapu (pomiary, kontrole negatywne, wyniki labu): `docs/PROJECT_STATUS.md`, wpisy z datami
2026-10-06 … 2026-10-16, oraz opisy PR-ów na GitHubie.

## 9. Wszystkie PR-y od 2026-10-05 (data scalenia, tytuł, pliki kodu poza docs/ i test/)

```text
#452 2026-10-05 | Publish the independent review finding for verify-endpoint history classification. |
#451 2026-10-06 | verify-endpoint: dluzsza retencja na kolektorze to nie martwy endpoint | zfs-backup.sh
#453 2026-10-06 | R5-8: progress_done zastepuje zakonczony koniec rekordu | lib-zfs-snap.sh
#454 2026-10-06 | status: blok testowy pgtest zdjety z crona roota na pve9 |
#455 2026-10-06 | silniki: bieg pominiety przez blokade -> 75 i ostrzezenie | snapget.sh snapsend.sh zfs-job.sh
#456 2026-10-06 | status: kolizja blokady na zywo |
#457 2026-10-06 | status: luka osieroconych nadan ZFS po uid; E69 |
#458 2026-10-06 | monitor: samotny - to wzorzec, nie flaga | zfs-backup.sh
#459 2026-10-06 | D1+U1: jedna relacja na pare hostow we wsadzie; --grant-remotely bez falszywego FATAL | deploy.sh zfs-backup.sh
#460 2026-10-06 | synchro jako lustro: snapget -M | gen-cron.sh snapget.sh tui/new-relation.sh tui/zfs-tui.py zfs-backup.sh
#461 2026-10-06 | fix: ponowna aktywacja daje istniejacej relacji synchro ksztalt lustra | zfs-backup.sh
#462 2026-10-06 | fix: straznik instalacji zna przejscie synchro na lustro | zfs-backup.sh
#463 2026-10-06 | replika na snapget -M (lustro nosnika) | cron2conf.sh gen-cron.sh snapget.sh
#464 2026-10-06 | U2, U5, U6, U8: rozrzut z godzina, ramki kreatora, F3, synchro z lancucha | tui/new-relation.sh tui/wt-lib.sh zfs-backup.sh
#465 2026-10-06 | U4: obce migawki na kolektorze backupu ciete jak wlasne | cron2conf.sh gen-cron.sh zfs-backup.sh
#466 2026-10-06 | set_or_remove_section_field: pole pod ostatnia linia sekcji | zfs-backup.sh
#467 2026-10-06 | U9: delete-relation --destroy-copies po seedzie bez aktywacji | zfs-backup.sh
#468 2026-10-06 | K4: konto synchro dostaje swoje ladowiska, nie ich rodzica | zfs-backup.sh
#469 2026-10-06 | K3: prune zrodla rozrzucony szczebel po szczeblu | gen-cron.sh zfs-backup.sh
#470 2026-10-07 | edit-relation: zmiana zainstalowanej relacji bez usuwania (CLI + GUI) | tui/edit-relation.sh tui/zfs-tui.py zfs-backup.sh
#471 2026-10-07 | replika: GUI na F6 i harmonogram on-insert (po wlozeniu) | gen-cron.sh tui/replica.sh tui/zfs-tui.py zfs-backup.sh
#472 2026-10-07 | delegowanie: Haiku 5.5 i rachunek tokenow w regulach rozdzialu pracy | CLAUDE.md
#473 2026-10-07 | K2, okno Relacja, K5: ekrany zgodne z cronem | tui/new-relation.sh tui/zfs-tui.py zfs-backup.sh
#474 2026-10-07 | K6: --leave konczy procesy konta przed userdel | deploy.sh
#475 2026-10-08 | K1: retencja zrodla w kreatorze dla szablonow -age | tui/new-relation.sh
#476 2026-10-08 | add-source: dataset do istniejacej relacji (CLI + GUI) i trzy wady przy okazji | tui/edit-relation.sh tui/new-relation.sh zfs-backup.sh
#477 2026-10-08 | replika: Del na F6 z opcjonalnym skasowaniem kopii na nosniku | tui/replica-delete.sh tui/zfs-tui.py zfs-backup.sh
#478 2026-10-08 | replika: wiersze na F2 i biegi w panelu | tui/zfs-tui.py
#479 2026-10-08 | replika: ostrzezenie, gdy kopia za dlugo nie przyszla | cron2conf.sh gen-cron.sh tui/replica.sh tui/zfs-tui.py zfs-backup.sh zfs-media-gate.sh
#480 2026-10-08 | P-0: kopia backupu podaza za zrodlem -- jedna polityka rozjazdu w obu silnikach | lib-zfs-snap.sh snapget.sh snapsend.sh
#481 2026-10-08 | GUI: synchro -> lustro; poprawka opisu P-0 | snapget.sh tui/new-relation.sh tui/zfs-tui.py
#482 2026-10-08 | P-0: lustro tez podaza za zrodlem, gdy sciezka nie jest dyskiem dzialajacego goscia | snapget.sh
#483 2026-10-08 | GUI: blad biegu i wyrzucenia P-0 na F2/F3; add-source zasiewa kazde nowe zrodlo | tui/zfs-tui.py zfs-backup.sh
#484 2026-10-08 | GUI: okno Zmień relację -- lista datasetów przycięta | tui/edit-relation.sh
#485 2026-10-08 | edit-config (crontab -e dla configu), /usr/local/bin/zfs-backup, GUI Edytuj config | deploy.sh tui/edit-relation.sh zfs-backup.sh
#486 2026-10-09 | gui: poprawki z rundy testow wlasciciela, paczka A | tui/* zfs-backup.sh
#487 2026-10-09 | gui: paczka B -- uwagi 4, 5, 11, 12 | tui/new-relation.sh zfs-backup.sh
#488 2026-10-09 | replika: tryb pasywny (uwaga 20) i harmonogram (16+19) -- paczka C1 | gen-cron.sh tui/* zfs-backup.sh zfs-media-gate.sh
#489 2026-10-09 | bramka nosnika: pasywna replika zawsze uruchamia kopie (E76) | zfs-media-gate.sh
#490 2026-10-09 | kopia lokalna jako relacja (L1): kreator Lokalnie, local-backup --name | tui/* zfs-backup.sh
#491 2026-10-09 | replika: prepare-media -- przygotowanie nosnika (uwaga 15) | tui/replica.sh zfs-backup.sh
#492 2026-10-09 | kopia lokalna L2: zmiana szablonu i datasetow relacji lokalnej | tui/edit-relation.sh zfs-backup.sh
#493 2026-10-09 | replika: ten sam koszyk datasetow co w relacji (uwaga 13) | tui/* zfs-backup.sh
#494 2026-10-09 | GUI: ekran F5 Szablony (uwaga 24) | tui/* zfs-backup.sh
#495 2026-10-09 | kreator relacji: retencja u zrodla jednym pytaniem (uwaga 2) | tui/new-relation.sh
#496 2026-10-09 | okna szablonu: zamrazanie jako kratka, opis z wyborow | tui/template.sh
#497 2026-10-09 | okno-tabela szczebli w curses: szablon F5 i retencja u zrodla | tui/*
#498 2026-10-09 | okno szablonu kompletne: zawsze pięć szczebli, save-profile --add-tier | tui/* zfs-backup.sh
#499 2026-10-09 | okno szablonu: wybór sposobu GFS / WIEK / PŁASKI z objaśnieniem | tui/* zfs-backup.sh
#500 2026-10-09 | GUI P1+P2: odświeżanie po powrocie, kursor w polach tabeli, wyłączanie szczebli | tui/* zfs-backup.sh
#501 2026-10-09 | GUI P3: klawisze F tylko na pasku, bez dubli | tui/zfs-tui.py
#502 2026-10-09 | GUI P4: relacja z szablonu albo ręcznie, jedno okno retencji źródła | tui/*
#503 2026-10-09 | P4: opis dokładniej | zfs-backup.sh
#504 2026-10-09 | GUI P5: replika rozpoznaje dyski po ID, nośnik tylko podłączony, po włożeniu per replika | gen-cron.sh tui/* zfs-backup.sh zfs-media-gate.sh
#505 2026-10-09 | P5: opis dokładniej | tui/replica.sh
#506 2026-10-09 | Kampania GUI 1: retencja źródła relacji lokalnej (E78), relacja lokalna na ekranach | tui/* zfs-backup.sh
#507 2026-10-12 | Testy GUI wlasciciela 10-11, paczka 1: W7, W11, W11b, ... F2 Uruchom teraz | gen-cron.sh tui/* zfs-backup.sh
#508 2026-10-12 | Testy GUI wlasciciela 10-11, paczka 2: W1, W4, W16 set-transfer, W18 keep, E79 stala replika | gen-cron.sh tui/* zfs-backup.sh
#509 2026-10-12 | W17: zaszyfrowane zrodlo wysylane zaszyfrowane (raw, -w) | gen-cron.sh lib-record.sh tui/* zfs-backup.sh
#510 2026-10-12 | Silniki (odmrozone): W19 cel pod zaszyfrowanym rodzicem, W14 cichy wpis przy zdjeciu migawek repliki | lib-zfs-snap.sh snapget.sh snapsend.sh
#511 2026-10-12 | Replika zaszyfrowanego zrodla wysyla zaszyfrowane (raw) | gen-cron.sh tui/replica.sh zfs-backup.sh
#512 2026-10-12 | Relacja lokalna: szablony zrodla __lsrc_ (E80) | zfs-backup.sh
#513 2026-10-12 | Zrodlowy szablon zdalny: osierocony szablon o tej nazwie jest zastepowany (E80) | zfs-backup.sh
#514 2026-10-12 | zfs-job: reczne uruchomienie (run-replicas, F8) dostaje prawdziwy kod | tui/zfs-tui.py zfs-backup.sh zfs-job.sh
#515 2026-10-12 | delete-relation: replika w configu zatrzymuje blok crona | zfs-backup.sh
#516 2026-10-12 | Replika: okno Ustawienia silnika (migawki, historia, na dysku) | tui/replica.sh
#517 2026-10-12 | W18: replica-restart -- replika po zerwaniu lancucha zaczyna od nowa na tym samym dysku | tui/replica.sh zfs-backup.sh
#518 2026-10-13 | GUI runda X: paczka drobna (X1-X5, X9, X11, X14) | tui/* zfs-backup.sh
#519 2026-10-13 | Replika: zaszyfrowany nosnik (W19b) | tui/* zfs-backup.sh zfs-media-gate.sh
#520 2026-10-13 | Zmien relacje: reczna zmiana configu nazwana w planie (X6) | tui/edit-relation.sh tui/hand-edits.py
#521 2026-10-13 | Config wygrywa z ukrytym szablonem relacji (krok 1) | tui/* zfs-backup.sh
#522 2026-10-13 | Szczeble relacji wprost w configu: show-tiers / set-tiers (etap A) | tui/* zfs-backup.sh
#523 2026-10-13 | Etap B: zrodla relacji lokalnej i Uzyj szablonu wprost w configu | tui/* zfs-backup.sh
#524 2026-10-13 | local_source_change: MANAGED_DATASETS rozdzielane spacja | zfs-backup.sh
#525 2026-10-13 | Etap C: usuniete uzgadnianie ukrytych szablonow z configiem | tui/* zfs-backup.sh
#526 2026-10-14 | GUI paczka 1: uwagi X15 X20 X23 X19 X10 X21 | tui/*
#527 2026-10-14 | X22: Uzyj szablonu we wlasne sekcje relacji + clean-templates | tui/* zfs-backup.sh
#528 2026-10-14 | X22: set-tiers dzieli sekcje wspolna dla obu stron relacji | zfs-backup.sh
#529 2026-10-14 | X24 X25 X26: ostrzezenie o nadpisaniu zrodla, sprzatanie configu roota, komunikat | tui/* zfs-backup.sh
#530 2026-10-14 | F7 na F5: Usun nieuzywane kopie szablonow + projekt X27 | tui/*
#531 2026-10-14 | X27 etap A: gen-cron czyta blok [relation:NAZWA] | gen-cron.sh
#533 2026-10-14 | X27 S1: sekcja relacji podaje strone wprost (side = target|source) | gen-cron.sh
#534 2026-10-14 | X27 S2+S3: czasowniki wprost na bloku [relation:], migrate-config | gen-cron.sh tui/edit-relation.sh zfs-backup.sh
#535 2026-10-14 | X27 S4 (cz. 1): sprzatanie -- szablony bez drabin, silnik w bloku, bez clean-templates/migrate-profile/cron2conf | cron2conf.sh gen-cron.sh profiles/default.conf tui/*
#536 2026-10-14 | X27 S4 (cz. 2): bez migrate-config; GUI "Same migawki" | tui/new-relation.sh zfs-backup.sh
#537 2026-10-15 | X27: pola silnika relacji przezywaja przebudowe (Uzyj szablonu) | zfs-backup.sh
#538 2026-10-15 | X27: pola silnika (i raw) przezywaja przebudowe relacji zdalnej | zfs-backup.sh
#539 2026-10-15 | restore: relacja lokalna nie konczy dyspozytora po cichu (rc=1 bez slowa) | zfs-backup.sh
#540 2026-10-15 | X12: wybor datasetow = drzewo z kratkami (curses) zamiast koszyka | tui/*
#541 2026-10-15 | restore: relacja lokalna do wczesniejszego punktu cofa zrodlo naprawde | zfs-restore.sh
#543 2026-10-15 | status NAZWA dla relacji lokalnej: wlasny widok | zfs-backup.sh
#542 2026-10-15 | Kolizja na jednym datasecie: odmowa w obrebie hosta, ostrzezenie przy kolektorze zdalnym | zfs-backup.sh
#544 2026-10-15 | restore --from-copy --overwrite: --at/--snapshot dociera do podgladu i wykonania | zfs-restore.sh
#545 2026-10-15 | restore: potwierdzenie nadpisania, klucz nosnika, droga usun+obok | zfs-restore.sh
#546 2026-10-15 | restore --with-history: odtworzenie obok z historia do punktu | zfs-restore.sh
#547 2026-10-15 | restore: replace na korzeniu zakresu -- bramka zglasza liste, pusty zakres odmawia | zfs-pair-gate.sh zfs-restore.sh
#548 2026-10-15 | restore: korzen zakresu = dataset z zakresu bez rodzica w zakresie | zfs-restore.sh
#549 2026-10-15 | restore: znikniety korzen zakresu, ponowne nadanie delegacji, prawdziwy raport kosztu | deploy.sh zfs-restore.sh
#550 2026-10-15 | deploy: bramka pary odswiezana z pakietem (refresh_pair_gate) | deploy.sh
#551 2026-10-15 | restore: zgoda na odzysk pauzuje relacje celu piszace do zakresu | deploy.sh lib-record.sh zfs-backup.sh
#552 2026-10-15 | restore: --plan --json -- punkty odzysku dla okna Przywroc | zfs-restore.sh
#553 2026-10-15 | restore: zgoda obejmuje <pula>/restore -- odzysk obok na celu | deploy.sh zfs-restore.sh
#554 2026-10-15 | gui: okno Przywroc z relacji (C2a) | tui/* zfs-backup.sh
#555 2026-10-15 | gui: okno Przywroc z dysku (C2b) -- F9 na F6 | tui/* zfs-backup.sh
#556 2026-10-15 | okna Przywroc: poprawki P1-P6 po testach wlasciciela | tui/* zfs-restore.sh
#557 2026-10-15 | okno Przywroc: granica --at (P7); restore: mapa GUID po odzysku (P8) | tui/restore.sh zfs-restore.sh
#558 2026-10-16 | docs: jeden kolektor + pvesr -- projekt, lab Metropolis, zgloszenie silnika snapget -s |
```

(PR #532 nie istnieje w `main` -- numer zużyty na PR niescalony.)
