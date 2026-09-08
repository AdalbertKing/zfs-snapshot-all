# Scalenie `snapsend.sh` i `snapget.sh` w `snapsync.sh` — wycena i zlecenie

Zlecenie właściciela, 2026-09-07: *„Znając stan projektu i obecność czasowników
wyceń zasadność deduplikacji skryptów snapsend.sh snapget.sh do jednego skryptu
i zostawienie ich dwóch jako cienkiej wersji."* Nazwa docelowa, decyzja
właściciela w tym samym dniu: **`snapsync.sh`**.

Dokument jest **zleceniem**, nie notatką. Każda liczba poniżej została
zmierzona na drzewie `c18436f` komendą, którą da się powtórzyć (sekcja 2);
każde ryzyko ma mitigację z miejscem w drzewie, gdzie już istnieje szew, na
którym można ją oprzeć. Wątek programisty ma zacząć od sekcji 9.

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

| ma `snapget.sh` | stan w `snapsend.sh` | klasyfikacja | skutek |
|---|---|---|---|
| **bramka rozjazdu celu** (`snapget.sh:1573-1700`): `recv_force_flag` liczony, odmowa „already exists and shares no common snapshot (by GUID) — needs -f", odmowa przy `written@baza ≠ 0`, odmowa przy snapshotach NOWSZYCH niż baza, `guest_disk_is_live`, podpowiedź o ZAMONTOWANYM celu przy `-F` | **nic z tego** — `recv_flags="-F -s"` bezwarunkowo (`snapsend.sh`, także ścieżka wznowienia) | **DRYF, P-0** — znaleziony w audycie 2026-09-07, nie było go w pierwszej wersji tej tabeli | push na rozjechany cel: przyrost z `-F` **cofa kopię po cichu**; brak wspólnej bazy → „standard full send" z `-F` **zastępuje istniejący cel**, tam gdzie pull odmawia i każe świadomie dać `-f`. Kampania REV-20260804-037/038 zbudowała tę bramkę tylko w pull |
| pomijanie rusztowania pod `-R -e`: trzy gałęzie skip (`No family` 1324, `Only excluded families` 1350, `No MESSAGE family` 1363) + bramka zbiorcza „wszystko było rusztowaniem → rc=1" (2595-2601) | **jedna** gałąź z trzech (`Only excluded families`, 1397) i **brak bramki zbiorczej** — `ADOPT_SKIPPED` jest inkrementowany i nigdy nie czytany | **DRYF** — ta sama flaga, ta sama ścieżka `USE_EXISTING_SNAPSHOT` | push `-R -e` nad pustym kontenerem ścieżki: **rc=1 „No source snapshots found"** tam, gdzie pull pomija; push, w którym każdy członek był rusztowaniem: **„All datasets processed successfully"** — fałszywy sukces |
| `local x; x=$(...)` wszędzie (0 masek) | **5** × `local x=$(...)` (825, 936, 937, 1241, 1611) | DRYF, higiena | pierwsza wersja tej tabeli twierdziła „porównanie GUID z pustym łańcuchem"; **nieprawda** — `validate_snapshot` w OBU silnikach odmawia przy pustym GUID (`[ -z ] → return 1`), więc maska ukrywała kod wyjścia, którego nikt nie czytał. Poprawione po przeczytaniu funkcji (E45) |
| linia `PLAN=INCREMENTAL\|FULL base= src= tgt=` | brak | **DRYF** (kontrakt czytany przez warstwę czasowników) | `seed` (push, `zfs-backup.sh:6734/6740`) nie może pokazać planu tak, jak `load`/`restore` |
| `guest_disk_is_live` na celu (1575) i podpowiedź „-F na ZAMONTOWANYM celu" (1761) | brak | część P-0 — obie siedzą wewnątrz bramki rozjazdu (`recv_force_flag`), nie da się ich portować osobno | jak wyżej |
| `-Q SEK` deadman zdalnego quiesce | brak flagi | **kierunkowe, nie portować** — deadman chroni zamrożonego gościa po ZDALNEJ stronie, gdy silnik padnie; w push gość jest lokalny i `on_exit` go odmraża | gen-cron słusznie nie emituje `-Q` na linii push |
| `probe_dataset` na źródle („nie ma" vs „ssh padł") | gołe `zfs list -H` | **kierunkowe, nie portować** — źródło push jest lokalne, `zfs list` nie ma trybu „ssh padł"; strona zdalna push idzie przez `target_exists` z biblioteki | — |

Pierwsza wersja tej tabeli liczyła `-Q` i `probe_dataset` jako braki push. Nie są nimi — obie różnice wynikają z tego, po której stronie jest ssh. Za to pierwszy wiersz jest gorszy, niż tabela mówiła: to nie „brak pomijania rusztowania", to **jedna flaga z dwoma zachowaniami**, w tym fałszywy sukces.

**Jak alarm został uciszony — i dlaczego to jest wada mechanizmu, nie ludzi.**
Commit `fd26421` (2026-08-21, „twins: record the deliberate snapget-only
divergence") błogosławi rozjazd `process_dataset` z uzasadnieniem: *„-e (adopt
the existing family) EXISTS only on pull; push creates its snapshots and has
no adoption path, so there is no equivalent fix to mirror."* To jest
nieprawda, sprawdzalna jednym grepem: `snapsend.sh:37` dokumentuje `-e`,
`USE_EXISTING_SNAPSHOT` prowadzi tę samą ścieżkę (`snapsend.sh:1371`), a dwa
dni później (2026-08-23) gałąź `Only excluded families` została do push
**zmirrorowana** — czyli ktoś już wtedy wiedział, że ścieżka istnieje. Alarm
zadał pytanie; odpowiedź była zdaniem bez numeru linii; suita przyjęła zdanie.
Wpis w `ENGINE-FREEZE.md` z 2026-08-21 autoryzuje **tylko** `snapget.sh` i
nie mówi ani słowa o bliźniaku. Trzy wpisy z 27-28.08 tak samo.

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
  zarejestrował **zero** wywołań `ssh` — w obu wrapperach;
- `snapsync.sh` wywołane bez wrappera (bez `--engine-name`/ograniczenia
  strony): rc≠0, zero `ssh`, zero `zfs` (P0);
- `snapsend.sh root@a:tank/x hdd/y` i `snapget.sh tank/x root@b:hdd/y`:
  odmowa sumy kontrolnej przed jakimkolwiek `zfs`.

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

**P0 — `snapsync.sh` NIE jest powierzchnią użytkownika.** Poprawka
właściciela, 2026-09-07 („błąd może być kosztowny"), po tym jak pierwsza
wersja tego dokumentu pokazała symetryczną składnię `snapsync.sh SRC DST`
z kierunkiem wynikającym z tego, która strona niesie `host:`. Koszt pomyłki
w tej gramatyce jest konkretny:

```
snapsync.sh -m auto_ root@pve9:tank/vm-101 hdd/backups/pve9   # pull: pisze lokalnie
snapsync.sh -m auto_ tank/vm-101 root@pve9:hdd/backups/pve9   # push: pisze NA pve9
```

Dziś `snapget.sh` fizycznie nie potrafi zrobić drugiego — cel z hostem jest
odmową gramatyki (v2.61+). **Nazwa skryptu jest drugim, niezależnym zapisem
tego, która strona jest pisana**, i symetryczna gramatyka tę redundancję
usuwa. Z `-f` (`snapget.sh:1461`: `zfs destroy -R` po całym poddrzewie celu)
pomyłka strony to skasowanie poddrzewa na hoście, na którym nikt nie
zamierzał nic pisać. Bariery, które dziś łapią pomyłkę — brak wspólnej bazy
GUID (1639), nowsze snapshoty/`written` na celu (1681/1683),
`validate_remote_host` — są tam, gdzie cel jest ZAJĘTY; nie ma ich tam,
gdzie cel jest pusty albo użytkownik dał `-f`, a to jest dokładnie
przestrzeń, w której symetryczna gramatyka dodaje nową pomyłkę.

Dlatego: gołe `snapsync.sh` bez `--engine-name` i bez ograniczenia strony
**odmawia** (rc≠0, zero `ssh`, zero `zfs`). Gramatyka użytkownika pozostaje
a) `snapsend.sh DATASETS [REMOTE]` i b) `snapget.sh REMOTE_DATASETS
[LOCAL_BASE]` co do znaku. `--src-side=local` / `--dst-side=local` z
wrappera to nie wygoda, tylko **suma kontrolna**: host po stronie, która „nie
może mieć hosta", jest odmową przed jakimkolwiek `zfs`. Jeśli kiedyś ma
powstać jeden czasownik dla ludzi, to w warstwie `zfs-backup.sh`, która zna
relację i kierunek z configu — nie w silniku.

Kształt wrapperów, który spełnia P0, P1 i P2 naraz:

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
`snapsync.sh` bez `--engine-name` odmawia (P0) — nie „bierze własnej nazwy",
jak mówiła pierwsza wersja tego akapitu.

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
| **0. Parytet** — plan naprawczy z sekcji 8, potrzebny niezależnie od scalenia | audyt parowany, pięć portów z sekcji 8.1, trzy mechanizmy z 8.2 | 4–6 |
| 1. Ciało główne | jeden parser argv w `snapsync.sh`, dwa wrappery, `ENGINE_NAME` zamiast `$0` (P1), test kluczy stanu | 1–2 |
| 2. Osiem funkcji kierunkowych | krotki per strona (M1); `process_dataset`, `transfer_data`, `find_*`, `validate_*`, `create_snapshot` jako jedna wersja; `_pg_wire` w obu kierunkach albo świadomie w jednym | 2–3 |
| 3. Testy | stub-dyskryminator (M2) napisany **przed** krokiem 2; `test/twins` przechodzi w test „wrapper = stary kontrakt" (argv, `-V`, klucze stanu, lockfile); `snapsend` (root+ZFS, lab), `remote --peer` (M3), `scenarios`, `evalfree`, `subtree`, `recursion`, `pairpause`, `runsuffix` z grafu `deps.conf` | 2–3 |
| 4. Domknięcie | `deploy.sh` (cztery pętle + `check_dep`), `ENGINE-FREEZE.md` + `--refreeze`, `deps.conf` (kontrakt `twin-functions` → `engine-wrappers`), `PROJECT_STATUS.md`, dziennik błędów | 1 |
| **razem** | | **10–14** (z czego 4–6 to sekcja 8, która ma sens sama) |

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
- **Nie wystawiać `snapsync.sh` ludziom ani cronowi.** Linia crona woła
  wrapper; `cron2conf.sh` ma nie wiedzieć, że silnik istnieje (P0).
- **Nie błogosławić `twins` zdaniem bez numeru linii.** `fd26421` jest
  dowodem, że zdanie może być fałszywe, a suita tego nie sprawdzi.
- **Nie robić tego w wątku GUI ani w wątku czasowników.** Zamrożone silniki
  wymagają własnej dyrektywy, własnej recenzji wstępnej i własnego okna na
  `remote --peer` na labie.

## 8. Plan naprawczy: parytet push↔pull (krok 0, ma sens sam)

Właściciel, 2026-09-07: *„snapget.sh rozjechał się merytorycznie ze
snapsend.sh — to niedopuszczalne. Przedstaw plan naprawczy."* Plan ma dwie
połowy: **porty** (co dziś jest rozjechane, z kontrolą negatywną per pozycja)
i **mechanizm** (dlaczego alarm nie zadziałał i co ma go zastąpić). Sama
lista portów bez mechanizmu jest tym, co projekt zrobił 2026-08-23
(`3b18fae`, „mirror the subtree verification into the push engine") — i
rozjazd wrócił w dwa dni.

### 8.1 Porty — pięć pozycji, każda z kontrolą negatywną na `c18436f`

Wszystkie w `snapsend.sh` (zamrożony → `authorizes-frozen: snapsend.sh`),
jedna REV, snapsend v2.72 → v2.73, `twins --bless` na końcu z odczytem obu
stron per funkcja.

| # | port | kontrola negatywna (dziś) | po porcie | koszt |
|---|---|---|---|---|
| **P-0** | **bramka rozjazdu celu**, cała: `recv_force_flag` (`-F` tylko na świeży cel), rozstrzyganie bazy po GUID, odmowa „shares no common snapshot — needs -f", odmowy `written@`/nowsze snapshoty, `guest_disk_is_live`, podpowiedź MOUNTED — wzór `snapget.sh:1573-1700`; dla zdalnego celu `written@`, `mounted` i status gościa czytane przez ssh (predykat gościa przez `quiesce_remote_run` po stronie celu, „nie wiem = odmowa" jak w pull) | **sekcja P, przypadek P5** w `test/snapsend` (tryb lokalny, bez ssh): cel z własnym `@other`, `-e` — pull odmawia i zostawia `@other`, push **zastępuje cel**, rc=0 | oba odmawiają tymi samymi słowami, `@other` przeżywa po obu stronach | 2–3 d + lab; **zmiana kontraktu push** (odmowa tam, gdzie dziś idzie) — wymaga słowa właściciela, nie jest objęta „Zacznij §8" |
| P-1 | `-R -e`: dwie brakujące gałęzie skip (`No family`, `No MESSAGE family`) + bramka zbiorcza `ADOPT_SKIPPED >= ${#DATASETS[@]} → rc=1` na końcu przebiegu (wzór `snapget.sh:2595-2601`) | push `-R -e` nad drzewem z pustym kontenerem ścieżki: rc=1 „No source snapshots found"; push, w którym każdy członek jest rusztowaniem: rc=0 „All datasets processed successfully" | pierwszy: skip + rc=0; drugi: rc=1 „nothing was adopted" | 0,5 d |
| P-2 | 5 × `local x=$(...)` → `local x; x=$(...)` (825, 936, 937, 1241, 1611) | stub `zfs` zwracający rc=1 na `get guid`: dziś `process_dataset` idzie dalej z pustym GUID | `return 1` na tej linii | 0,5 d (kontrola jest trudniejsza niż fix — to jest cały koszt) |
| P-3 | linia `PLAN=INCREMENTAL\|FULL base= src= tgt=` na stdout w tym samym miejscu, co `snapget.sh` | `snapsend.sh -n` nie drukuje `PLAN=`; `seed` w `zfs-backup.sh` nie ma czego czytać | drukuje; `seed` może pokazać plan | 0,5 d |
| P-4, P-5 | **złożone do P-0** — `guest_disk_is_live` i podpowiedź MOUNTED siedzą wewnątrz bramki `recv_force_flag`; osobno byłyby strażnikiem przed bezwarunkowym `-F` | — | — | w P-0 |

Nie portowane, z powodem zapisanym w `twins.sha256` (8.2 M-a): `-Q`
(deadman chroni zdalnie zamrożonego gościa; w push gość jest lokalny),
`probe_dataset` na źródle (lokalne `zfs list` nie ma trybu „ssh padł").
Odwrotny kierunek sprawdzony też: `canmount_noauto_subtree*` z push ma
w pull odpowiednik inline (`snapget.sh:1836`) — równoważne, nie dryf.

### 8.2 Mechanizm — trzy zmiany, żeby to nie wróciło

**M-a — różnica bez powodu nie przechodzi.** `twins.sha256` dostaje dla pary
o różnych hashach obowiązkową trzecią kolumnę: `direction:<jedno zdanie z
numerem linii>` albo `port-by:<REV lub data>`. Suita: para różna bez powodu
→ FAIL; `port-by` z datą w przeszłości → FAIL. `--bless` bez powodu dla
różnej pary → odmowa. Alarm przestaje być pytaniem, na które można
odpowiedzieć zdaniem; staje się terminem. `fd26421` w tym mechanizmie nie
mógłby przejść: „-e exists only on pull" musiałoby wskazać linię, a
`snapsend.sh:37` mówi co innego.

**M-b — scenariusze parowane w `test/snapsend/run.sh`.** Dziś suita ma 77
wywołań `run_send` i 28 `run_get`, asercje per silnik, nie per para. Nowa
sekcja **P**: każdy scenariusz trybu lokalnego (ten sam argv w obu silnikach —
sekcja 2) uruchamiany **obydwoma** silnikami na tym samym drzewie i
asercjonowany na **identyczny** rc, identyczny zbiór powstałych datasetów i
snapshotów, identyczne `PLAN=`. `-R -e` nad pustym kontenerem wchodzi jako
pierwszy scenariusz P — jest kontrolą negatywną P-1. Kandydaci z dzisiejszej
suity: wszystkie 28 `run_get`, bo dla nich `run_send` z tym samym argv jest
poprawnym wywołaniem. Tryb lokalny jest jedynym, w którym oba silniki mają
być **nieodróżnialne** — więc to jest miejsce na test nieodróżnialności.

**M-c — autoryzacja jednego silnika nazywa bliźniaka.** Wpis w
`ENGINE-FREEZE.md`, który nazywa dokładnie jeden z `snapsend.sh`/`snapget.sh`,
musi zawierać linię `twin: ported in <commit>` albo `twin: n/a — <powód z
numerem linii>`. `./test/impact.sh --verify` sprawdza to grepem (wpis
z jedną nazwą silnika bez `twin:` → FAIL). Cztery istniejące wpisy z 21.08
i 27-28.08 dostają tę linię wstecznie, z prawdziwą odpowiedzią — dla 21.08
brzmi ona „NIE zportowane, P-1 w sekcji 8.1", nie „n/a".

### 8.2a Stan po pierwszej rundzie (2026-09-07, „Zacznij §8, odmrażam snapsend.sh")

Zrobione na gałęzi, snapsend v2.73: **P-1, P-2, P-3**; **M-a** (kolumna
powodu w `twins.sha256`, sekcja B2, `--bless` odmawia bez powodu — kontrole
negatywne: wiersz bez powodu → FAIL, termin miniony → FAIL, bless bez powodu →
rc=1 i plik nietknięty); **M-b** (sekcja P w `test/snapsend`: P1 `-R -e` nad
rusztowaniem, P2 samo rusztowanie, P3 `PLAN=` na `-n`, P4 pełny+przyrost, P5
rozjechany cel); **M-c** (`impact.sh --verify`: wpis freeze nazywający jeden
silnik bez linii `twin:` → FAIL; cztery wpisy uzupełnione prawdziwą odpowiedzią,
trzy z nich brzmią „NIE zportowane — P-0"). `twins` 81/0, `evalfree` 16/0
tutaj. **`test/snapsend` NIE uruchomione** — w tym środowisku `zpool` jest
odmówiony; sekcja P i porty P-1/P-3 czekają na lab (root+ZFS). Do czasu labu
twierdzenia o zachowaniu są lustrem, nie pomiarem (R12). Na labie **P5 będzie
czerwone dla push** — z założenia, dopóki P-0 nie wejdzie.

Nie zrobione: **P-0**. To zmiana kontraktu push (odmowa tam, gdzie dziś cofa
lub zastępuje) i wymaga jawnego słowa właściciela; `process_dataset` niesie
`port-by:2026-09-21` w `twins.sha256`, więc B2 zapali się sam, gdy termin
minie bez decyzji.

### 8.3 Kolejność i koszt

| etap | dni |
|---|---|
| audyt parowany: 15 funkcji × (identyczna / kierunkowa z linią / dryf) + odwrotny kierunek; wynik jako kolumna powodu w `twins.sha256` (M-a) | 1 |
| M-b sekcja P z pierwszym scenariuszem `-R -e` czerwonym (kontrola P-1) | 1 |
| P-1 … P-5 pod `authorizes-frozen: snapsend.sh`, każdy z kontrolą; `snapsend` na labie (root+ZFS); v2.73 | 2–3 |
| M-c w `impact.sh` + cztery wpisy wstecz; `--refreeze`; `PROJECT_STATUS`; dziennik błędów | 0,5–1 |
| **razem** | **4–6** |

Po tym etapie scalenie (kroki 1–3 z sekcji 6) zaczyna od dwóch silników,
które w trybie lokalnym są nieodróżnialne z dowodem, a w trybach zdalnych
różnią się tylko tam, gdzie `twins.sha256` mówi dlaczego. Bez tego etapu
scalenie musiałoby wybierać, która wersja `process_dataset` jest prawdziwa —
a P-1 pokazuje, że dziś **żadna** z nich nie jest kompletna.

## 9. Start dla wątku programisty

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

Pierwszy commit: **sekcja 8** (krok 0), jako własna REV pod
`authorizes-frozen: snapsend.sh`, w kolejności 8.3: audyt → sekcja P z
czerwonym `-R -e` → P-1 … P-5 → M-c. Każda pozycja z kontrolą negatywną na
`c18436f`. Dopiero po zielonym `snapsend` na labie i zapisie w
`PROJECT_STATUS.md` — zlecenie na kroki 1–4 z sekcji 6, z M2 jako pierwszym
plikiem.
