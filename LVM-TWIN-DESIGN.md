# Bliźniaczy toolkit dla ext4 + LVM-thin — plan projektowy

Stan: **szkielet do dyskusji**. Celem dokumentu jest spójny plan podziału na
warstwy zachowane i warstwy pisane od nowa, z jawnie nazwanymi decyzjami i
ryzykami — nie kompletna specyfikacja. Szczegóły oznaczone "do dopieszczenia
później" są świadomie odłożone.

## Kontekst i motywacja

Toolkit dziś obsługuje wyłącznie ZFS. Proxmox na storage LVM-thin nie ma
natywnej replikacji (pvesr działa tylko na ZFS), a nisza "syncoid dla
LVM-thin" jest praktycznie pusta. Analiza kodu pokazuje, że ~80% repo
(konfiguracja INI, profile/tiery, generowanie crona, retencja GFS, alerting,
transport ssh/mbuffer/kompresja, szkielet testów) jest niezależne od backendu;
ZFS-owe jest ~20% skupione w silnikach `snapsend.sh` / `snapget.sh` /
`lib-zfs-snap.sh` oraz w delegacji `zfs allow` wewnątrz `deploy.sh`.

**Cel: projekt siostrzany, w którym warstwy wyższe pozostają nienaruszone, a
wymianie podlega wyłącznie rdzeń snapshot/replikacja.**

## Zakres zmian per plik

| Plik dziś | W bliźniaku | Zakres |
|---|---|---|
| `gen-cron.sh`, `lib-cron.sh`, `cron2conf.sh` | bez zmian | **nienaruszone** — składnia INI, tiery, szablony, instalacja crontaba identyczne |
| `lib-scope.sh` | bez zmian funkcjonalnych | gramatyka `pc_is_dataset` obsługuje już `VG/LV` (te same reguły komponentów); 2 wywołania `zfs list` → odpowiedniki `lvs` za wspólnym seamem |
| `delsnaps.sh` | adaptacja cienka | matematyka GFS (epoki, wieże) bez zmian; wymiana enumeracji `zfs list`→`lvs` i `zfs destroy`→`lvremove` |
| `check-snap-age.sh` | adaptacja cienka | logika duration/Nagios bez zmian; źródło wieku: `lvs -o lv_name,lv_time` |
| `zfs-backup.sh` | **`vg-backup.sh`** | zmiana nazwy + słownictwa; maszyna stanów klientów, rekordy, `--pair`, sekwencjonowanie — bez zmian logiki |
| `zfs-quiesce-helper.sh` | `quiesce-helper.sh` | logika `qm`/`pct` bez zmian; mapowanie wolumen→guest czyta nazwy LV `vm-<id>-disk-<n>` (Proxmox nazywa LV-y identycznie jak datasety) |
| `deploy.sh` | adaptacja | bootstrap, sudoers, klucze, alerting, self-update — bez zmian; fazy `zfs allow` zastąpione modelem uprawnień z sekcji "Model uprawnień"; zależności: `thin-provisioning-tools` zamiast `zfs` |
| `snapsend.sh` | **rdzeń pisany od nowa** | ta sama nazwa, ten sam kontrakt CLI (sekcja "Kontrakt CLI") |
| `snapget.sh` | **rdzeń pisany od nowa** | jw. |
| `lib-zfs-snap.sh` | **`lib-lvm-snap.sh`** | podsystemy ssh/ControlMaster, tune, quiesce, locking, stats przeniesione żywcem; część ZFS pisana od nowa |

**Decyzja: `snapsend.sh` i `snapget.sh` zachowują nazwy.** Nazwy są
backend-neutralne ("snap send/get"), a to one są wpisywane w wygenerowane
linie crona — zachowanie nazw jest warunkiem nietykalności `gen-cron.sh`,
`cron2conf.sh` i większości fixtures. Zmieniamy nazwy tylko plikom z "zfs" w
nazwie.

## Wymóg twardy: LVM-thin, nie klasyczne LVM

Klasyczne (grube) snapshoty LVM odpadają: stały rozmiar rezerwowany z góry,
degradacja wydajności zapisu proporcjonalna do liczby snapshotów, brak
narzędzi delta. Cały projekt zakłada **thin pool**: snapshoty thin są tanie,
a `thin_delta` (z pakietu `thin-provisioning-tools`) potrafi wyliczyć różnicę
bloków między dwoma thin-wolumenami tego samego poola.

Adres wolumenu w configu: `VG/LV` (dwa komponenty). Nie ma hierarchii
datasetów — nie ma kontenerów, nie ma dziedziczenia, nie ma rekursji
drzewiastej. Selekcja "wielu wolumenów" to enumeracja LV-ów w VG filtrowana
prefiksem/regexem (dzisiejsze `-X` działa bez zmian).

## Silnik replikacji

### Snapshot

`lvcreate -s --name <lv>_<PREFIX><timestamp> VG/LV` — konwencja nazw
identyczna z dzisiejszą (`automated_hourly_2026-08-05_14-00-00`), tylko
separator `@` zastąpiony `_` (LVM nie dopuszcza `@` w nazwach LV; parser nazw
w retencji i monitoringu dostaje jeden wspólny helper `snap_name_split`).

### Przyrost

Sekwencja dla `send -i old new`:

1. Rezerwacja metadata snapshot na poolu (`dmsetup message ... 0
   reserve_metadata_snap`) — **sekcja krytyczna per pool**, chroniona
   flockiem; release w trap EXIT.
2. `thin_delta --snap1 <dev_id old> --snap2 <dev_id new> /dev/mapper/<tmeta>`
   → lista różniących się zakresów bloków.
3. Sender czyta wskazane zakresy z urządzenia snapshotu `new` i emituje
   **własny framowany strumień**: nagłówek (magia, wersja, UUID bazy, UUID
   snapshotu, rozmiar bloku poola), potem ramki `(offset, długość, dane,
   crc32)` uporządkowane rosnąco po offsecie, stopka z sumą całości.
4. Strumień wchodzi w **istniejący, niezmieniony `transfer_data()`**
   (zstd/pigz → ssh → mbuffer → odbiornik) — potok jest już dziś agnostyczny,
   przyjmuje `send_cmd`/`recv_cmd` jako stringi.
5. Odbiornik waliduje nagłówek (UUID bazy musi zgadzać się z ostatnim
   zaaplikowanym — patrz "Model stanu"), zapisuje ramki w docelowy LV,
   po sukcesie robi lokalny `lvcreate -s` o tej samej nazwie snapshotu.

Pełny seed = ten sam format strumienia, ale zakresy ze zmapowanych bloków
wolumenu (`thin_dump` mappings zamiast delty) — nie kopiujemy dziur, więc
seed cienkiego wolumenu przenosi tylko dane rzeczywiście zapisane.

Odpowiednik `-I` (wszystkie pośrednie): sekwencja delt kolejnych par
snapshotów wysyłana jedna po drugiej, z lokalnym `lvcreate -s` na celu po
każdej. Odpowiednik `-i` (pomiń pośrednie): jedna delta `oldest→newest`.
Semantyka `-T <N>` (próg catch-up) przenosi się bez zmian.

### Wznawianie (odpowiednik resume token)

Ramki są uporządkowane po offsecie, więc odbiornik prowadzi **high-water
mark** (ostatni w pełni zapisany i zsynchronizowany offset) w pliku stanu.
Przerwany transfer wznawia się przez ponowne uruchomienie sendera z
parametrem `--resume-from <offset>` — sender pomija zakresy poniżej znaku
wodnego. Licznik prób i sprzątanie jak dziś (`MAX_RESUME_ATTEMPTS`,
`abandon`). Słabsze niż token ZFS (wymaga powtórzenia `thin_delta`), ale
funkcjonalnie pokrywa przypadek "342 GB padło na 90%".

## Model stanu — największy kawałek nowego designu

ZFS dawał nam za darmo: GUID-y, bookmarki, holdy, resume tokeny. LVM nie daje
nic z tego. Zastępniki:

| Mechanizm ZFS | Zastępnik | Nośnik |
|---|---|---|
| GUID snapshotu | UUID generowany przy `lvcreate`, wspólny dla źródła i celu (przenoszony w nagłówku strumienia) | **tag LV** (`lvchange --addtag uuid=<...>`) + plik stanu |
| dopasowanie wspólnej bazy | przecięcie list snapshotów po nazwie (fast path), fallback po UUID z tagów | `lvs -o lv_name,lv_tags` po obu stronach |
| bookmark | brak odpowiednika bez kosztu — **decyzja: wspólną bazę chronimy retencją, nie bookmarkiem**: retencja odmawia skasowania ostatniego snapshotu oznaczonego tagiem `lastsync=<target-tag>` (odświeżanym po każdym udanym transferze, per para target+identifier jak dziś `tgt-<8hex>`) | tag LV |
| `zfs hold` | tag `inflight=<job-key>` zakładany przed transferem, zdejmowany po; `delsnaps` odmawia kasowania otagowanych | tag LV — **ochrona doradcza, nie kernelowa**; egzekwowana tylko przez nasze narzędzia |
| resume token | high-water mark + licznik prób | plik w `$LOCKDIR` (dzisiejszy wzorzec `job_state_key()` md5 z NUL-delimiterami — bez zmian) |
| `receive -F` rollback | `lvremove` snapshotów nowszych niż wspólna baza + merge/odtworzenie LV z bazy | sekwencja lvm |

Tagi LV są trwałe (przeżywają rename LV, restart hosta), widoczne
międzyprocesowo i nie wymagają naszych plików — to najbliższy odpowiednik
properties. Pliki stanu pozostają tym, czym są dziś: dwa drobiazgi per job.

**Uczciwie o degradacji gwarancji:** ochrona in-flight przestaje być
kernelowa. `lvremove` wykonany ręcznie lub przez obce narzędzie zniszczy
snapshot mimo taga. Dziś kod ZFS explicite odrzuca ochronę doradczą jako
niewystarczającą — w wersji LVM **akceptujemy ją świadomie** i dokumentujemy,
bo lepszej nie ma.

## Atomowość i quiesce

Nie istnieje atomowy snapshot wielu LV. Sekwencja dla gościa z N dyskami:

1. `fsfreeze` przez qemu-guest-agent (dzisiejszy mechanizm `-q`, bez zmian),
2. sekwencyjne `lvcreate -s` per dysk wewnątrz okna,
3. thaw.

`lvcreate -s` na thin trwa ~dziesiątki ms, więc kilka–kilkanaście dysków
mieści się w twardym limicie okna (~10 s, jak dziś dla Windows). Guard: przed
freeze liczymy dyski; jeśli szacowany czas przekracza budżet okna —
przerywamy z alertem zamiast ryzykować timeout agenta. Spójność
**między dyskami tego samego gościa** jest zapewniona przez freeze (I/O
zamrożone na wszystkich naraz), nie przez atomowość snapshotu — to
wystarczające i tożsame z gwarancją, jaką daje dziś freeze + `zfs snapshot`
per pool.

Bez quiesce (`-q` nieużyte): snapshoty per LV są niezależne czasowo —
crash-consistent per dysk, bez spójności między dyskami. Identyczna
degradacja jak dziś przy datasetach w różnych poolach.

## Kontrakt CLI — macierz zgodności flag

Warunek nietykalności warstw wyższych: **nowe silniki przyjmują dzisiejsze
flagi**. Trzy kategorie:

- **Bez zmian semantyki:** `-m` (prefix), `-j` (identifier), `-b` (bwlimit),
  `-A` (autotune; próbka strumienia z odczytu LV zamiast `zfs send | head`),
  `-z`/`-Z`/`-N` (kompresja), `-K`/`-O` (ssh), `-X` (wykluczenia), `-T`
  (catch-up), `-e` (użyj istniejącego), `-i`/`-I`, `-F` (reconcile), `-V`,
  `-n` (dry-run), `-l` (log), `-y` (yes).
- **Reinterpretacja:** `-R` (flat recurse) = enumeracja LV-ów w VG po
  prefiksie nazwy; `-r` (rekursja atomowa) = alias do `-R` z ostrzeżeniem
  (nie ma drzewa, nie ma atomowości — freeze załatwia spójność); `-S`
  (skip parent) = no-op z ostrzeżeniem (nie ma kontenerów).
- **Odrzucane z czytelnym błędem:** `-w` (raw/encrypted send — brak
  odpowiednika; szyfrowanie to LUKS na innej warstwie), `-u`/`-U`
  (mount celu — snapshoty LVM nie montują się same; do rozważenia
  `--activate` jako przyszłe rozszerzenie).

`gen-cron.sh` emituje flagi z pól configu — pola mapujące się na flagi
odrzucane walidujemy na poziomie configu (komunikat wskazuje pole INI, nie
flagę). Lista pól do przejrzenia względem `--dump-fields` — do dopieszczenia
później.

## Retencja i monitoring

- `delsnaps.sh`: enumeracja `lvs --select 'lv_name =~ ...' -o
  lv_name,lv_time`, kasowanie `lvremove`. Wieże GFS, wiek, count — bez zmian.
  Ochrona prefiksów Proxmoxa traci rację bytu (brak pvesr na LVM), ale
  zostaje ochrona tagów `inflight`/`lastsync`.
- `check-snap-age.sh`: wiek z `lv_time`, reszta bez zmian.
- **Nowy obowiązkowy monitor: zapełnienie thin poola.** `lvs -o
  data_percent,metadata_percent` z progami warn/crit w configu. Przepełniony
  thin pool to awaria katastrofalna (błędy zapisu wszystkich thin LV naraz) —
  ten monitor jest ważniejszy niż odpowiednik `zpool status` i wchodzi w
  istniejący potok alertów bez zmian w samym alertingu. Zdrowie dysków:
  poza zakresem (mdadm/smartctl to inne narzędzia; odnotować w README).

## Model uprawnień

`zfs allow` nie ma odpowiednika — LVM nie deleguje uprawnień per wolumen.

**Decyzja na fazę 1: root-only.** Węzły Proxmox i tak operują jako root, a
parytet z trybem `--as=root` z PAIRING-DESIGN.md jest wystarczający na start.

**Faza późniejsza: konto delegowane przez sudo-whitelist**, wzorcem
`zfs-quiesce-helper.sh` — repo ma już przećwiczony schemat wąskiej listy
poleceń za sudo z walidacją argumentów. Wrapper `lvm-helper` z listą:
`lvcreate -s`, `lvremove` (tylko nazwy pasujące do naszej konwencji
snapshotów!), `lvs`, `lvchange --addtag/--deltag` (tylko nasze przestrzenie
tagów), `thin_delta`, `dmsetup message ... reserve/release_metadata_snap`.
Walidacja argumentów w wrapperze jest tu warstwą bezpieczeństwa, nie
kosmetyką — `lvremove` bez ograniczenia wzorca to root-equivalent. Szczegóły
do dopieszczenia później.

## Testy

- **Suity `needs=nothing`** (gencron, cron, scope, tune, statekey, ...):
  przechodzą bez zmian lub z podmianą stubów `zfs`→`lvs`/`lvcreate` w PATH —
  dzisiejszy idiom stubów-rejestratorów przenosi się wprost.
- **Suity integracyjne** (`snapsend`, `delsnaps`, `scenarios`): odpowiednik
  sparse-file zpool = plik sparse → `losetup` → `vgcreate` → `lvcreate
  --type thin-pool`; PID-owany suffix, trap EXIT z `vgremove` + `losetup -d`
  — ta sama postawa bezpieczeństwa co dziś (`sendtest$$`).
- **`test/impact.sh` + `deps.conf`**: przenoszone bez zmian; `needs = root,
  zfs` → `needs = root, lvm-thin, loop`.
- Fixtures golden `gen-cron`: re-blessing tylko tam, gdzie wygenerowany tekst
  crona zawiera flagi odrzucane — po walidacji pól configu powinno być tego
  mało.

## Ryzyka i niewiadome (kolejność wg wagi)

1. **Wydajność i stabilność `thin_delta` na dużych poolach** — działa na
   metadata snapshot całego poola; czas i zachowanie przy setkach GB metadanych
   nieznane. Prototyp (faza 0) ma to zmierzyć zanim powstanie linia kodu
   silnika właściwego.
2. **Rezerwacja metadata snapshot jest globalna per pool** — dwa równoległe
   joby na tym samym poolu muszą się serializować na tym kroku (flock);
   wpływ na przepustowość przy wielu parach do zmierzenia.
3. **Okno freeze vs sekwencyjne lvcreate** przy gościach z wieloma dyskami —
   guard liczbowy opisany wyżej; do pomiaru w praktyce.
4. **Brak odpowiednika bookmarków** — jeśli retencja na źródle i tak skasuje
   ostatnią wspólną bazę (bug, ręczna ingerencja), jedyną drogą jest re-seed.
   Częstotliwość tego scenariusza w praktyce zdecyduje, czy trzeba czegoś
   mocniejszego (np. wymuszony minimalny keep=1 dla snapshotów `lastsync`).
5. **Własny format strumienia = własna odpowiedzialność za poprawność** —
   crc per ramka + suma całości + UUID-y łańcucha w nagłówku; test suite musi
   mieć przypadki uszkodzonego strumienia od pierwszego dnia.

## Fazy realizacji

0. **Prototyp (spike, wyrzucalny):** dwa VG na loop-device na jednym hoście;
   `thin_delta` → framowany strumień → apply; pomiar czasu delty i seedu na
   realistycznym wolumenie. Kryterium wyjścia: delta 100 GB wolumenu w czasie
   porównywalnym z `zfs send -i` na tym samym sprzęcie (rząd wielkości).
1. `lib-lvm-snap.sh`: przeniesienie podsystemów agnostycznych żywcem +
   snapshot/delta/apply/stan z prototypu.
2. `snapsend.sh` (push, lokalny i ssh) na nowym libie; suita integracyjna
   loop-VG.
3. `snapget.sh` (pull) + reconcile `-F`.
4. `delsnaps.sh` + `check-snap-age.sh` + monitor thin poola.
5. Walidacja nietykalności: `gen-cron`/`cron2conf`/`lib-cron`/`lib-scope`
   przechodzą swoje suity bez modyfikacji kodu; re-blessing fixtures tylko
   udokumentowany.
6. `vg-backup.sh` (rename + słownictwo) i `deploy.sh` (zależności, fazy
   uprawnień, smoke test).
7. Dokumentacja: README bliźniaka + tabela degradacji gwarancji względem
   wersji ZFS (jawna, na wzór sekcji "Core concepts").

Punkt decyzyjny po fazie 0: jeśli `thin_delta` nie spełni kryterium,
alternatywy to `bdsync` (czyta cały wolumen przy każdym runie — akceptowalne
dla małych flot) albo rezygnacja z przyrostów blokowych na rzecz
rsync-po-zamontowanym-snapshocie (tylko ext4, wolne dla obrazów VM) — obie
istotnie zmieniają rachunek opłacalności projektu i wracamy z nimi do
dyskusji, nie decydujemy w kodzie.
