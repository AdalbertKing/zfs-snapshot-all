# Scalenie `snapsend.sh` i `snapget.sh` w `snapsync.sh` — wycena i zlecenie

Zlecenie właściciela, 2026-09-07: *„Znając stan projektu i obecność czasowników
wyceń zasadność deduplikacji skryptów snapsend.sh snapget.sh do jednego skryptu
i zostawienie ich dwóch jako cienkiej wersji."* Nazwa docelowa, decyzja
właściciela w tym samym dniu: **`snapsync.sh`**.

Dokument jest **zleceniem**, nie notatką. Każda liczba poniżej została
zmierzona na drzewie `c18436f` komendą, którą da się powtórzyć (sekcja 2);
każde ryzyko ma mitigację z miejscem w drzewie, gdzie już istnieje szew, na
którym można ją oprzeć. Wątek programisty ma zacząć od sekcji 8.

## 1. Werdykt

**Zasadne — ale nie jako „deduplikacja", tylko jako scalenie dwóch kierunków
transferu w jeden silnik, pod recenzją, w dwóch krokach.** Koszt 8–11 dni
roboczych plus dwa cykle recenzji (pliki są zamrożone). Powód, dla którego
warto: bliźniaki już się rozjechały, a alarm dryfu `test/twins` — przyjęty
2026-08-04 *zamiast* scalenia — jest błogosławiony, nie egzekwowany
(sekcja 3). Dedup łatwy jest zrobiony od dawna (`lib-zfs-snap.sh`, 3146
linii); to, co zostało, to jedna logika z dwiema tabelami współrzędnych.

Czego ten dokument **nie** twierdzi: że scalenie jest tanie, że można je
zrobić bez recenzji wstępnej, ani że decyzja z 2026-08-04 była błędna w dniu
podjęcia. Była trafna na danych, jakie wtedy istniały. Dane się zmieniły.

## 2. Pomiary

Drzewo: `c18436f` (main po zamknięciu REV-136). `snapsend.sh` v2.72,
`snapget.sh` v2.70.

| miara | `snapsend.sh` | `snapget.sh` |
|---|---|---|
| linii ogółem | 2644 | 2617 |
| linii kodu (bez komentarzy i pustych) | 1131 | 1186 |
| identyczne linie kodu, multizbiór | **872 (~75 % każdego)** | |
| linii komentarza | 996 | 863 |
| funkcje zdefiniowane w pliku | 17 | 16 |
| nazwy wspólne | 15 | 15 |
| tylko po jednej stronie | `canmount_noauto_subtree`, `canmount_noauto_subtree_cmd` | `guest_disk_is_live` |
| ciało główne (poza funkcjami), linii kodu po normalizacji | 418 | 436 — **240 różnych** |

Per funkcja (linie ogółem; ostatnia kolumna = linie różniące się w `diff`):

| funkcja | send | get | różne | charakter różnicy |
|---|---|---|---|---|
| `announce_transfer_size` | 22 | 22 | 0 | identyczna |
| `human_bytes` | 9 | 9 | 0 | identyczna |
| `declare_recursion` | 4 | 4 | 0 | identyczna |
| `opt_takes_arg` | 3 | 3 | 0 | identyczna |
| `cluster_needs_next` | 11 | 11 | 0 | identyczna |
| `translate_long_options` | 46 | 46 | 0 | identyczna |
| `get_sorted_snapshots` | 29 | 32 | 15 | identyczny hash po normalizacji `twins` (różnica to komentarze) |
| `validate_snapshot` | 18 | 20 | 6 | strona zdalna w innym slocie |
| `create_snapshot` | 10 | 17 | 13 | get tworzy snapshot przez ssh, send lokalnie |
| `validate_subtree` | 37 | 39 | 20 | strona zdalna w innym slocie |
| `find_recursive_name_collisions` | 45 | 32 | 21 | jak wyżej + get krótszy |
| `find_common_snapshot` | 66 | 61 | 25 | jak wyżej |
| `find_conflicting_snapshots` | 57 | 56 | 53 | jak wyżej — „53 z 57" z decyzji 08-04 wciąż prawdziwe |
| `transfer_data` | 104 | 108 | 68 | kształt potoku: `zfs send \| ssh recv` vs `ssh send \| recv`; plik `_pg_wire` tylko w get |
| `process_dataset` | 601 | 727 | 530 (po normalizacji: **353 vs 383, 250 różnych**) | patrz niżej |

**Obserwacja, której decyzja z 2026-08-04 nie miała.** W `process_dataset`
obie strony wywołują **dokładnie ten sam zbiór funkcji** — zero wywołań
unikalnych dla którejś strony (zmierzone: wyciąg `\b[a-z_]+\(` z obu ciał po
normalizacji, `comm -23` i `comm -13` puste). Różnica to mechanicznie zamienione
sloty argumentów:

```
send:  check_pool_health "$src_dataset" "" ""
       [ -n "$remote_host" ] && check_pool_health "$tgt_dataset" "$remote_user" "$remote_host"
get:   [ -n "$remote_host" ] && check_pool_health "$src_dataset" "$remote_user" "$remote_host"
       check_pool_health "$tgt_dataset" "" ""

send:  resume_token=$(get_resume_token "$tgt_dataset" "$remote_user" "$remote_host")
get:   resume_token=$(get_resume_token "$tgt_dataset" "" "")

send:  hold_snapshot "$snapshot" "" ""
get:   hold_snapshot "$snapshot" "$remote_user" "$remote_host"
```

To nie jest rozbieżność logiki. To jedna logika, w której każde wywołanie
dostaje współrzędne *tej strony, której dotyczy*, a obie kopie kodują te
współrzędne konwencją („`remote_*` to cel" w send, „`remote_*` to źródło" w get)
zamiast danymi. Helpery w `lib-zfs-snap.sh` już przyjmują `user host` per
wywołanie — dlatego różnica jest mechaniczna.

**Tryb lokalny — duplikacja stuprocentowa.** Oba silniki obsługują relację
jednoserwerową (kopia do drugiego datasetu na tym samym hoście) z **tym samym
argv**: `snapsend.sh -m auto_ pool/data backuppool/kopie` i
`snapget.sh -m auto_ pool/data backuppool/kopie` piszą to samo miejsce.
W snapget element bez `:` to źródło lokalne (`snapget.sh:349-352` — „no ssh,
used for local-to-local relocation/testing"; parser `2316-2318` zostawia
`_item_host` pusty), w snapsend `REMOTE` bez `:` i `@` to lokalna baza
(`snapsend.sh:2329`). Suita `test/snapsend/run.sh` uruchamia snapget właśnie
tak — 27 wywołań `run_get` — i to jest relacja jednoserwerowa, jakie flota
prowadzi dziś przez snapget. W tym trybie nie ma strony zdalnej, więc nie ma
nawet zamienionych slotów: obie kopie `process_dataset` i `transfer_data`
wykonują tę samą gałąź (`COMPRESSION` wymuszone na 0, `snapget.sh:1184` ma
własną odmowę `src == tgt` przy pustym hoście). Decyzja z 08-04 opisuje trzy
tryby (push, pull, lokalny-tylko-w-suicie); czwarty — lokalny w produkcji —
jest tym, w którym „rozbieżność" wynosi zero. Poprawka właściciela,
2026-09-07: pierwsza wersja tego dokumentu twierdziła, że snapget nie kopiuje
lokalnie. Nie sprawdziłem tego w kodzie przed napisaniem — E38 w dzienniku
błędów, ten sam odruch.

Komendy, którymi to zmierzono (do powtórzenia po każdej zmianie):

```bash
# rozmiary kodu i część wspólna
for f in snapsend snapget; do grep -vE '^\s*(#|$)' $f.sh > /tmp/$f.code; wc -l < /tmp/$f.code; done
comm -12 <(sort /tmp/snapsend.code) <(sort /tmp/snapget.code) | wc -l
# funkcje per plik i różnice
comm -12 <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' snapsend.sh | sort) \
         <(grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' snapget.sh | sort)
# wyciąg jednej funkcji do pliku: awk od 'nazwa()' do pierwszego '^}'
# wywołania unikalne dla strony w process_dataset
grep -oE '\b[a-z_]+\(' /tmp/pd.send | sort -u > /tmp/c.s; grep -oE '\b[a-z_]+\(' /tmp/pd.get | sort -u > /tmp/c.g
comm -3 /tmp/c.s /tmp/c.g            # puste = ten sam zbiór wywołań
```

## 3. Co się zmieniło od odrzucenia scalenia (2026-08-04)

Decyzja „alarm dryfu zamiast scalenia" jest zapisana w trzech miejscach:
`docs/PROJECT_STATUS.md` (wpis „ROZWAŻONE I ODRZUCONE"), nagłówek
`test/twins/run.sh`, kontrakt `[contract:twin-functions]` w `test/deps.conf`.
Zakładała, że alarm utrzyma parytet, bo „poprawka w jednym kierunku jest
PYTANIEM o drugi". Historia od tego dnia mówi, jaka jest odpowiedź:

- commity od 2026-08-04 dotykające **tylko jednego** silnika: **snapsend 1,
  snapget 10** (`git log --since=2026-08-04 --name-only -- snapsend.sh snapget.sh`);
- `test/twins/twins.sha256` błogosławione **22 razy** (`git log --oneline -- test/twins/twins.sha256 | wc -l`);
- z 15 wspólnych nazw tylko 7 ma dziś identyczny hash w `twins.sha256`.

Dziesięć commitów tylko-snapget, imiennie: `88bf38e` i `29f4f1a` (`-R -e`:
dziecko bez rodziny to rusztowanie, nie awaria; v2.69→v2.70), `d3cdd77` i
`7e82961` (postęp na żywo — ta gałąź, która faktycznie się wykonuje),
`1aabaa8` (weryfikacja całego poddrzewa, nie tylko korzenia), `f5fb237`,
`f2231a1`, `b3b3758`, `9a30cac` (restore F9/F10/F21: odmowy i środki zaradcze,
których konto delegowane może użyć), `3a78b1d` (kotwica nośnika). Część jest
naprawdę tylko-pull (restore idzie przez pull). Część nie jest i push ich
nie ma:

| ma `snapget.sh` | brak w `snapsend.sh` | skutek dla warstwy czasowników |
|---|---|---|
| `-Q SEK` deadman zdalnego quiesce | brak flagi | gen-cron nie może jej emitować na linii push |
| linia `PLAN=INCREMENTAL\|FULL base= src= tgt=` | brak | `seed` (push, `zfs-backup.sh:6734/6740`) nie może pokazać planu tak, jak `load`/`restore` |
| `probe_dataset` z rozróżnieniem „nie ma" / „ssh padł" (`case $? in 1) 2)`) | gołe `zfs list -H` | w push „nie ma" i „nie odpowiada" to ten sam komunikat |
| pomijanie rusztowania pod `-R -e` (`ADOPT_SKIPPED`) | brak | ta sama konfiguracja `-R -e` zachowuje się inaczej w każdym kierunku |
| `local x; x=$(...)` wszędzie (0 masek) | **5** × `local x=$(...)` | kod wyjścia polecenia zamaskowany — dokładnie wada, którą kontrakt `twin-functions` cytuje jako dowód dryfu, wciąż w drzewie po miesiącu |

Wniosek: push jest kierunkiem drugiej kategorii. A to push obsługuje `seed`
i nośniki wymienne (`cron2conf.sh` parsuje nawiasy nośnika tylko wokół
`snapsend.sh`). Alarm działa jako pytanie; odpowiedź coraz częściej brzmi
„bless i dalej".

## 4. Ryzyko z 2026-08-04 i jak je zamknąć

Powód odrzucenia był prawdziwy i pozostaje prawdziwy: **parametr kierunku
ustawiony odwrotnie jest fail-open przy wykrywaniu wspólnej bazy** — pyta
niewłaściwy host o GUID, dostaje pustą odpowiedź, wnioskuje, że bazy nie ma
(albo że jest), a `test/snapsend` jest LOCAL MODE ONLY z założenia
(`validate_remote_host` słusznie przerywa przy tym samym `/etc/machine-id`),
więc przy pustych `remote_user`/`remote_host` obie gałęzie zwijają się do tego
samego wywołania i suita strukturalnie nie może tego złapać.

Trzy mitigacje, żadna z nich nie istniała w argumentacji z 08-04:

**M1 — nie parametr kierunku, tylko dwie jawne krotki.** `snapsync.sh` liczy
raz na wejściu `SRC_USER SRC_HOST TGT_USER TGT_HOST` (dla push:
`"" "" $remote_user $remote_host`; dla pull odwrotnie) i **każde** wywołanie w
`process_dataset` dostaje krotkę tej strony, której dotyczy:
`check_pool_health "$src_dataset" "$SRC_USER" "$SRC_HOST"`. Nie ma zmiennej
`DIRECTION`, na którą można by się pomylić w środku ciała; jest tylko „to
dotyczy źródła" / „to dotyczy celu", a diff z sekcji 2 pokazuje, że to jest
cały problem. Konwencja („`remote_*` to cel") przestaje istnieć jako
konwencja i staje się danymi.

**M2 — dyskryminator bez ZFS: stub `ssh`, który zapisuje, KOGO zapytano.**
`test/snapsend/run.sh:1266` już podmienia `ssh` w `PATH` (`stubbin`) — szew
istnieje. Nowy stub loguje `host + polecenie` do pliku; suita uruchamia
`snapsync.sh` w obu kierunkach z **niepustym** `remote_host` na fałszywym
hoście i asercjonuje:

- pull: `zfs list ... guid` dla `src` poszło **przez ssh** do `remote_host`,
  dla `tgt` **nie poszło** przez ssh;
- push: odwrotnie;
- `zfs snapshot` (create) poszło przez ssh tylko w pull;
- `zfs hold` poszło na tę samą stronę, co `zfs snapshot`;
- argv bez hosta po żadnej stronie (relacja jednoserwerowa): stub
  zarejestrował **zero** wywołań `ssh` — w obu wrapperach i w gołym
  `snapsync.sh`.

To zamyka fail-open na czystym tekście, w sekundach, w CI. Test pisze się
**przed** pierwszą zmianą w `process_dataset` (R7: kontrola negatywna —
zamiana krotek w jednej linii ma go zapalić).

**M3 — druga strona granicy.** `test/remote/run.sh --peer` na labie (pve9 +
drugi host) jako dowód, że to samo dzieje się z prawdziwym ssh (R2). Bez tego
suita M2 dowodzi kształtu, nie zachowania.

## 5. Kontrakt cienkich wrapperów — trzy pułapki zmierzone w drzewie

Wrappery `snapsend.sh` i `snapget.sh` zostają jako pliki o tych nazwach, bo na
nazwach wiszą: linie crona emitowane przez `gen-cron.sh`, parsery
`parse_send_cmd`/`parse_get_cmd` w `cron2conf.sh` (`*/snapsend.sh -m "*`,
`*/snapget.sh -m "*`), siedem wywołań w `zfs-backup.sh` (`$SNAPSEND` ×2,
`$SNAPGET` ×5), cztery pętle instalacyjne w `deploy.sh` (4322, 4396, 6980,
7004) i tabela wersji w `PROJECT_STATUS.md`. Nic z tego nie musi się zmienić —
pod trzema warunkami:

**P1 — nazwa silnika jest jawnym parametrem, nie `$0`.** `$(basename "$0")`
jest **kluczem stanu na flocie**: `LOCKFILE` (`snapsend.sh:2247`,
`snapget.sh:2290`), `job_state_key`, `legacy_state_file`, `resume_state_file`,
`inflight_snap_file` i kolumna narzędzia w `emit_stats`
(`lib-zfs-snap.sh:47,378,384,393,527`). Wrapper wykonujący
`exec bash snapsync.sh` zmieniłby `$0` na `snapsync.sh` — każda relacja na
flocie straciłaby licznik prób wznowienia, zapis snapshotu in-flight i
blokadę, a `delsnaps.sh` przestałby rozpoznawać hold. Silnik dostaje
`ENGINE_NAME=snapsend.sh` (zmienna albo pierwszy argument wewnętrzny) i **to**
podstawia wszędzie, gdzie dziś jest `basename "$0"`. Test: klucze stanu i
nazwa lockfile identyczne przed i po, na tych samych argumentach — to jest
asercja, którą `test/twins` ma zastąpić (sekcja 6).

**P2 — `-V` i argv per wrapper.** `snapsend.sh -V` musi dalej mówić
`snapsend.sh v2.7x`, `snapget.sh -V` swoje; wersje **rozjeżdżają się
celowo** (2.72 vs 2.70) i jedno scalenie ma je zrównać w tym samym commicie,
z zapisem w tabeli wersji. Kształt argv nie jest symetryczny: push
`DATASETS [REMOTE]`, pull `user@host:DS,... [LOCAL_BASE]` z parsowaniem hosta
per element (~40 linii tylko w get, `RAW_DATASETS`/`_item_host`). Wrapper
normalizuje to do jednego wewnętrznego kształtu (`--src-side=local|remote`,
lista datasetów, baza) — **nie** przepycha dwóch parserów do `snapsync.sh`.
`OPTSTRING` też się różni (`-Q` tylko w get; kolejność `q:`) — jedno
`OPTSTRING` w silniku, wrapper push odrzuca `-Q` do czasu, aż deadman ma sens
w push (albo i nie odrzuca — to decyzja, nie przypadek; zapisać ją).

Kształt wrapperów, który spełnia P1 i P2 naraz:

```bash
# snapsend.sh -- cienki: nazwa silnika jawna, źródło nie może nieść hosta
exec bash "$DIR/snapsync.sh" --engine-name=snapsend.sh --src-side=local "$@"
# snapget.sh  -- cienki: cel nie może nieść hosta
exec bash "$DIR/snapsync.sh" --engine-name=snapget.sh --dst-side=local "$@"
```

`--src-side`/`--dst-side` to **ograniczenia**, nie kierunek: wrapper mówi
„ta strona nie może mieć hosta", a `snapsync.sh` i tak wylicza krotki
`SRC_*`/`TGT_*` z argumentów (M1). Dla wywołania bez hosta oba ograniczenia
są spełnione, więc `snapsend.sh pool/data backuppool/kopie` i
`snapget.sh pool/data backuppool/kopie` trafiają do tego samego kodu —
jedyna różnica to `ENGINE_NAME`, czyli klucz stanu. Relacja jednoserwerowa
prowadzona dziś przez `snapget.sh` ma stan pod `snapget.sh.*` w `$LOCKDIR`
i po scaleniu ma go tam dalej mieć; to jest cały powód P1. Gołe
`snapsync.sh` bez `--engine-name` bierze własną nazwę — nowa relacja, nowy
klucz, poprawnie, bo nikt jej wcześniej nie prowadził.

**P3 — pliki zamrożone.** `snapsend.sh`, `snapget.sh`, `lib-zfs-snap.sh` są
w `docs/project/ENGINE-FREEZE.md`; `snapsync.sh` ma tam trafić w tym samym
commicie, w którym powstaje. Ścieżka: dyrektywa właściciela → recenzja
wstępna z `authorizes-frozen: snapsend.sh snapget.sh lib-zfs-snap.sh` →
implementacja → `./test/impact.sh --refreeze`. Recenzja wstępna jest też
właściwym miejscem, żeby Recenzent **formalnie uchylił decyzję z 08-04** na
podstawie sekcji 2–3, a nie żeby implementer ją obchodził.

## 6. Plan i koszt

| krok | zakres | dni |
|---|---|---|
| **0. Parytet** — potrzebny niezależnie od scalenia | port do push tego, co w tabeli sekcji 3 jest neutralne kierunkowo: `probe_dataset`, rusztowanie pod `-R -e`, linia `PLAN=`, 5 × `local x=$(...)`; decyzja o `-Q` w push zapisana; `twins --bless` z odczytem obu stron | 2 |
| 1. Ciało główne | jeden parser argv w `snapsync.sh`, dwa wrappery, `ENGINE_NAME` zamiast `$0` (P1), test kluczy stanu | 1–2 |
| 2. Osiem funkcji kierunkowych | krotki per strona (M1); `process_dataset`, `transfer_data`, `find_*`, `validate_*`, `create_snapshot` jako jedna wersja; `_pg_wire` w obu kierunkach albo świadomie w jednym | 2–3 |
| 3. Testy | stub-dyskryminator (M2) napisany **przed** krokiem 2; `test/twins` przechodzi w test „wrapper = stary kontrakt" (argv, `-V`, klucze stanu, lockfile); `snapsend` (root+ZFS, lab), `remote --peer` (M3), `scenarios`, `evalfree`, `subtree`, `recursion`, `pairpause`, `runsuffix` z grafu `deps.conf` | 2–3 |
| 4. Domknięcie | `deploy.sh` (cztery pętle + `check_dep`), `ENGINE-FREEZE.md` + `--refreeze`, `deps.conf` (kontrakt `twin-functions` → `engine-wrappers`), `PROJECT_STATUS.md`, dziennik błędów | 1 |
| **razem** | | **8–11** |

Plus dwa cykle recenzji: wstępna (P3) i końcowa. Krok 0 może iść jako własna
REV i **zwraca się sam**, nawet gdyby kroki 1–3 nigdy nie nastąpiły.

Kolejność jest istotna: bez kroku 0 scalenie musiałoby przy każdej z ośmiu
funkcji wybierać, która wersja przeżyje, i to jest dokładnie miejsce, gdzie
ginie zachowanie. Po kroku 0 wybór jest jeden: krotki zamiast konwencji.

Zysk po stronie kodu: ~1100 linii zduplikowanego kodu mniej, 22 błogosławieństwa
`twins` mniej rocznie, koniec z „push nie ma". Zysk po stronie czasowników:
`seed` dostaje `PLAN=`, gen-cron może emitować te same flagi w obu kierunkach,
a `set-scope`/`set-tiers` z listy `OWNER-MISSING-VERBS-2026-09-07.md` renderują
na jeden zbiór flag zamiast dwóch.

Styk z wątkiem czasowników: **brak kolizji plików** — tamten pracuje w
`zfs-backup.sh`, ten w silnikach i `lib-zfs-snap.sh`. Jedyny wspólny fakt to
linia `PLAN=` (krok 0 daje ją pushowi; czasownik `seed` może ją czytać dopiero
potem). Wątek silników nie dotyka `gen-cron.sh` ani `cron2conf.sh` — jeśli
dotknie, to jest sygnał, że wrapper nie dotrzymał P2.

## 7. Czego nie robić

- **Nie scalać `delsnaps.sh`.** Ma własną kopię `json_escape` przypiętą
  kontraktem `json-escape` i dwa homonimy (`destroy_one`, `emit_stats`) o
  innych sygnaturach — to nie jest bliźniak, to sąsiad.
- **Nie zmieniać kluczy stanu** ani na jeden dzień. Flota ma zapisy
  in-flight i liczniki wznowień pod `snapsend.sh.*`/`snapget.sh.*` w
  `$LOCKDIR`; migracja kluczy to osobna zmiana z osobną recenzją, jeśli
  kiedykolwiek.
- **Nie błogosławić `twins` w trakcie kroków 1–2.** Alarm ma zapalić się raz,
  na końcu, gdy obie strony są jedną funkcją; do tego czasu czerwony `twins`
  to informacja, nie przeszkoda.
- **Nie zaczynać od `process_dataset`.** Zaczyna się od M2 (stub) i P1
  (nazwa silnika), bo to są asercje, pod którymi reszta ma się zmieniać.
- **Nie robić tego w wątku GUI ani w wątku czasowników.** Zamrożone silniki
  wymagają własnej dyrektywy, własnej recenzji wstępnej i własnego okna na
  `remote --peer` na labie.

## 8. Start dla wątku programisty

```bash
git fetch origin main && git log --oneline -1 origin/main
sed -n '1,120p' docs/internal/IMPLEMENTER-ERROR-LOG.md        # sekcja 1, obowiązkowo
grep -v CLOSED docs/internal/reviews/REVIEW_LEDGER.md          # czy coś jest OPEN | Claude
sed -n '1,60p' test/twins/run.sh                               # decyzja 08-04 w jej własnych słowach
sed -n '/^\[contract:twin-functions\]/,/^check/p' test/deps.conf
sed -n '1,80p' docs/project/ENGINE-FREEZE.md                   # ścieżka authorizes-frozen
grep -n 'basename "\$0"' lib-zfs-snap.sh snapsend.sh snapget.sh # P1: klucze stanu
sed -n '1255,1275p' test/snapsend/run.sh                       # szew stubbin dla M2
git log --since=2026-08-04 --format='%h %s' -- snapget.sh      # krok 0: co portować
./test/impact.sh                                               # co trzeba uruchomić
```

Pierwszy commit: **krok 0**, jako własna REV pod `authorizes-frozen`, w
kolejności: 5 × `local x=$(...)` → `probe_dataset` → rusztowanie `-R -e` →
`PLAN=` → decyzja o `-Q`. Każda pozycja z kontrolą negatywną na `c18436f`.
Dopiero po zielonym `snapsend` na labie i zapisie w `PROJECT_STATUS.md` —
zlecenie na kroki 1–4, z M2 jako pierwszym plikiem.
