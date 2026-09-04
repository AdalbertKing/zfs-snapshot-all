# Decyzja: backend LVM w zfs-snapshot-all

Status: **PROJEKT DO ZATWIERDZENIA przez właściciela** (2026-09-04). Spisany
przez implementera z dyskusji z właścicielem; punkty oznaczone **[decyzja]**
są rozstrzygnięte w tej dyskusji, punkty **[propozycja]** czekają na słowo
właściciela. Żadna linia kodu nie powstała; ten dokument ma wyprzedzić
pierwszą.

## 1. Dwie decyzje, które już padły

**[decyzja] Parowanie dla LVM to wariant root-only.** Nie ma odpowiednika
`zfs allow`, więc nie ma delegacji konta. Wariant już istnieje w pakiecie:
`deploy.sh --as=root` — `--join` pomija scope i grant („root already has full
authority on this host, there is nothing to scope / to grant"), `--unpair`
tylko sprząta stan. Dla LVM to jedyny dozwolony wariant.

**[decyzja] `gen-cron.sh` nie jest warstwą ZFS.** Generator posługuje się
silnikami (`snapsend.sh`, `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh`),
nie komendami `zfs`. Zmierzone 2026-09-04: poza komentarzami woła `zfs`/`zpool`
tylko w `--reconcile` (czasownik z natury ZFS-owy) i w nawiasie nośnika
(`zpool import`). Lint `flags` czyta optstringi silników zamiast nieść własną
kopię gramatyki. Wniosek: backend to pole w sekcji CONFIG i wybór trójki
silników do emisji plus ich optstringów do lintu; generator zostaje w
warstwie tekstowej, wspólny dla obu backendów.

## 2. Zakres LVM — co wchodzi, czego nie ma

Czego LVM nie ma i pakiet **nie będzie udawał, że ma**:

| własność ZFS | LVM | skutek |
|---|---|---|
| `zfs allow` (delegacja konta) | brak | zadania jako root, relacja root-only (§1) |
| `zfs send -i` (przyrost) | tylko `thin_delta` na thin poolu | domyślnie pełny obraz; przyrost **[propozycja]** dopiero w drugim kroku, tylko dla thin |
| GUID snapshotu jako tożsamość | brak (UUID LV + czas) | weryfikacja odtworzenia po sumie kontrolnej, nie po GUID |
| holdy, bookmarki | brak | brak ubezpieczenia ciągłości; utrata bazy = pełny obraz |
| drzewo datasetów, `recursive` | brak (płaska VG) | `recursive` odmawia (§4) |
| `canmount`, `mountpoint` | aktywacja LV | `-U`/`canmount` bez odpowiednika, ignorowane z ostrzeżeniem albo odmowa (§4) |
| `zfs rollback` do snapshotu | `lvconvert --merge` (cofa w miejscu) | restore LVM to inny model niż Faza 7; **poza pierwszym zakresem** |

Pierwszy zakres **[propozycja]**: snapshot lokalny po harmonogramie, retencja
po wzorcu, monitoring wieku, wypchnięcie pełnego obrazu snapshotu przez ssh
(`dd | ssh dd`, z `mbuffer` jak dziś). Bez restore, bez pull, bez przyrostu.

## 3. Silniki LVM — nowe skrypty, ten sam kontrakt

Trzy nowe skrypty w bashu, obok ZFS-owych, nie zamiast nich:

| ZFS | LVM | robota |
|---|---|---|
| `snapsend.sh` | `lvmsend.sh` | `lvcreate -s -n <lv>_<prefix><ts> -L <rozmiar>` (albo thin bez `-L`), opcjonalnie `dd if=/dev/vg/snap \| mbuffer \| ssh … dd of=` |
| `delsnaps.sh` | `lvmdel.sh` | `lvremove` snapshotów po wzorcu nazwy i wieku, ta sama drabina retencji |
| `check-snap-age.sh` | `lvm-snap-age.sh` | wiek najmłodszego snapshotu z `lvs -o lv_name,lv_time` |

Kontrakt: **ten sam podzbiór gramatyki flag** co silniki ZFS (`-m PREFIX`,
`-y/-m/-w/-d/-h`, `-p/-k/-c/-K/-O` dla ssh, `-q`, `-n`), z tymi samymi
kontraktami z `deps.conf` (`gen-cron-flags`, `ssh-flag-parity`,
`account-paths`) rozszerzonymi o nowe pliki. Flagi bez odpowiednika (`-r`,
`-R`, `-A`, `-z`, `-e`, `-b` bookmark) silnik LVM **odrzuca po nazwie**, nie
ignoruje. Nazewnictwo snapshotu: LV nie zna `@`; nazwa snapshotu to
`<lv>_<prefix><ts>` w tej samej VG, a wzorzec retencji dopasowuje sufiks
**[propozycja]**. Pola pomiarowe (`emit_stats`, log JSON-lines) w tym samym
schemacie, żeby digest nie musiał rozróżniać backendów.

Zamrożenie: silniki LVM od pierwszego commita w `ENGINE-FREEZE.md` na tych
samych zasadach? **[propozycja]: nie**, do czasu pierwszego dowodu na żywo;
freeze po labie.

## 4. CONFIG v4 — pole `backend` i cztery pola o ZFS-owym kształcie

`[dataset:<ścieżka>]` dostaje **[propozycja]** `backend = zfs|lvm`
(domyślnie `zfs`, więc każdy istniejący config znaczy to samo, co dziś).
Ścieżka sekcji dla LVM to `vg/lv`. `gen-cron.sh` przy `lvm` emituje trójkę z
§3 i lintuje `flags` optstringami tych silników.

Pola, których znaczenie ma ZFS-owy kształt, i rozstrzygnięcie dla `lvm`:

| pole | dziś | `backend = lvm` |
|---|---|---|
| `recursive = flat/atomic` | drzewo datasetów, `-r`/`-R` | **odmowa** z nazwą pola („LVM nie ma drzewa; wypisz LV osobno") |
| `autotune`, `compression` | próbkowanie strumienia `zfs send` | `autotune` **odmowa**; `compression` przechodzi do transportu (`dd \| zstd \| ssh`), bez próbki **[propozycja]** |
| `history = all/newest` | `zfs send -I` | **odmowa** w pierwszym zakresie (pełny obraz nie ma historii) |
| `media = removable` | `zpool import/export` w nawiasie | `vgchange -ay/-an` + `vgs` jako sprawdzenie tożsamości; ten sam kształt nawiasu **[propozycja]** drugi krok, nie pierwszy |
| `passive`, `exclude_family`, `exclude` | rodziny snapshotów w drzewie | `passive` bez zmian (konsumuje cudze snapshoty po wzorcu), `exclude*` **odmowa** (brak drzewa) |
| `quiesce` | freeze guesta przed snapshotem | bez zmian (mechanizm nie zależy od backendu) |
| `bandwidth`, `cipher`, `ssh_flags`, harmonogramy, retencja, `notify` | transport i czas | bez zmian |

Zasada: **odmowa przed emisją, nie ignorowanie** — ta sama, którą generator
stosuje do `-f`/`-n` dziś. Pole, które dla LVM nic nie znaczy, kończy
`gen-cron.sh` z nazwą sekcji i pola; nie renderuje linii, która o 2 w nocy
zrobi coś innego, niż config obiecał.

## 5. `deploy.sh` i `zfs-backup.sh` — co się zmienia po stronie relacji

- `--pair` z `backend = lvm` (albo flagą `--backend=lvm` **[propozycja]**)
  wymusza `--as=root`; `--local-user` odmawia (dla roli `pull` deleguje korzeń
  celu przez `zfs allow`, czego nie ma).
- Linie crona LVM idą do crontaba roota; kontrakt `account-paths` bez zmian
  dla roota.
- `zfs-backup.sh add-client`/`activate` w pierwszym zakresie **nie obsługują**
  LVM (ścieżka wysokopoziomowa jest zbudowana na `resolve_mode_datasets` i
  profilach z rodzinami snapshotów); LVM wchodzi ścieżką niskopoziomową
  (`--pair` → wsad → `--join` → CONFIG ręczny). To spójne z wynikiem labu
  `--draft-config`: ta ścieżka jest w użyciu.
- `--draft-config` dla LVM listuje `lvs` zamiast `zfs list` **[propozycja]**
  drugi krok.

Koszt bezpieczeństwa, do zapisania w `PROJECT_STATUS.md` i w pomocy: pomoc
`--as=root` mówi „use only when the hosts already fully trust each other".
**Każda relacja LVM jest z definicji w tej klasie.** Klucz relacji otwiera
roota na peerze; izolacji per relacja nie ma.

## 6. Dowody, zanim cokolwiek trafi na flotę

- `gen-cron.sh`: fixture CONFIG z `backend = lvm` dla każdego kształtu z §4
  (przechodzące i odmowy z nazwą pola), round-trip przez `cron2conf.sh`
  (nowy `parse_lvm_cmd` lustrem `parse_send_cmd`), kontrakt `gen-cron-flags`
  rozszerzony o silniki LVM — suita `gencron` i `cron2conf`, bez roota.
- Silniki: suity tekstowe jak `test/recursion`/`test/runsuffix` dla gramatyki
  i odmów; zachowanie na żywo w labie z runbookiem po zasadach E32/E34
  (każda flaga zgrepowana, każda komenda doprowadzona do dispatchu, hold
  przez plik, nic jako root na checkoucie dewelopera).
- `deadcode`, `twins`-owe pinowanie kopii (jeśli `lvmsend.sh` weźmie coś z
  `lib-zfs-snap.sh`, np. `emit_stats`/`json_escape`, to przez wyprowadzoną
  bibliotekę wspólną, nie kopię; `deadcode`/`twins` to złapią).
- Lab na jednym hoście z VG poza produkcją (thin pool osobno, jeśli §2 drugi
  krok wejdzie).

## 7. Otwarte — do słowa właściciela

1. Pierwszy zakres z §2: snapshot, retencja, wiek, pełny obraz przez ssh —
   bez restore, pull, przyrostu, nośnika. Tak?
2. Nazewnictwo snapshotu LV (`<lv>_<prefix><ts>`) i rozmiar snapshotu
   (`-L` stały w polu CONFIG, np. `snap_size = 10%ORIGIN`, albo tylko thin).
3. `compression` dla LVM: w transporcie bez próbki, czy odmowa jak `autotune`.
4. Czy relacja LVM ma w ogóle wchodzić w `peers/`/`relationships/`
   (manifest, klucz, `clean-relationships.sh`), czy być „tylko cron lokalny"
   w pierwszym kroku — to decyduje, ile z §5 wchodzi teraz.
5. Zamrożenie silników LVM: od pierwszego commita czy po labie.
6. Python: ta praca nie wymaga wyboru scenariusza; jeśli B ma wejść, pole
   `backend` w generatorze jest naturalnym pierwszym elementem tłumaczenia.
