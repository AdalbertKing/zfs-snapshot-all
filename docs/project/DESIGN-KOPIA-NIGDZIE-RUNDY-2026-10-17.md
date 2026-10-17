# Relacja „kopia: nigdzie” — rozpisanie na rundy (2026-10-17)

Status: **projekt do przeczytania, nic nie kodowane.** Silnik jest zrobiony: `snapget -s`
(REV-20261016-148, zamknięte). Ten dokument opisuje warstwę między silnikiem a GUI.

Poprzedniki: `DESIGN-JEDEN-KOLEKTOR-PVESR-2026-10-16.md` (po co),
`ENGINE-REMOTE-SNAPSHOT-ONLY-2026-10-16.md` (silnik), `LAB-METROPOLIS-PVESR-PLAN-2026-10-16.md`
(pomiary).

## Dwa warianty „tylko migawki” po wdrożeniu

- **Lokalnie** (już jest): GUI „Same migawki (na tym hoście, bez kopii)”. Cron, migawki,
  przycinanie i monitor działają na hoście, który ma datasety, niezależnie od kolektora.
- **Zdalnie** (ten projekt): cron na kolektorze robi migawki na źródle przez ssh, bez kopii.

Oba warianty są do wyboru w tym samym kroku „Jaka relacja?”.

## Czym jest relacja

To zwykła relacja pull między kolektorem B a źródłem A, z jedną różnicą: **nic nie jest
kopiowane**. Cron na B uruchamia `snapget.sh -s user@A:dataset`, a migawka powstaje na A. Na
B nie ma celu ani kopii.

Skutki, które już przyjąłeś:

- **Kolektor leży → na źródle nie ma nowych migawek** ani przycinania. Źródło stoi na
  ostatnim stanie. Po powrocie kolektora następny bieg robi świeżą migawkę, bez nadrabiania
  zaległych.
- **Źródło wskazuje administrator** przy zakładaniu relacji. Narzędzie nie wykrywa, gdzie
  jest gość („narzędzie, nie AI”, właściciel 2026-10-16).
- **Po migracji gościa** nasze migawki na starym węźle znikają przy następnej replikacji
  (`recv -F`, zmierzone 16.10, 15:15–15:45). Chroni przed tym **alarm monitora wieku**
  (runda 2). Przeniesienie relacji to ruch człowieka.

## Co dziś stoi na przeszkodzie (z kodu)

| miejsce | dziś | problem dla „kopii nigdzie” |
|---|---|---|
| `zfs-backup.sh add-client` (`--mode`, ~9290) | tylko `backup` albo `sync`; pusty `--target` zastępuje `DEFAULT_TARGET`, a bez niego jest błąd (~9545) | „bez celu” nie da się wyrazić |
| rekord relacji, `CLIENT_TARGET` | pusty cel = **lustro** (`sync`): JSON `mode` (~17523), GUI `rel_type` | nowa relacja byłaby czytana jako lustro |
| `snapget_local_base` (~4962) | dla nie-sync zwraca `<cel>/<etykieta>` | bez celu wyszłoby `/<etykieta>` |
| `cmd_seed`, strażnik pokrycia (`coverage_conflicts` ~4008) | liczą ścieżki na kolektorze | tu nie ma ścieżek na kolektorze |
| `edit-relation` add-source (~13880) | bez celu: „names no target”, odmowa | trzeba gałęzi dla tego trybu |
| `gen-cron.sh` pull (~3509–3571) | `snapget.sh -m P … src [baza]`, `pull_check` wymaga ścieżki lokalnej | brak gałęzi renderującej `snapget -s` |
| `check-snap-age.sh` (nagłówek, linie 17–19) | **tylko lokalnie**, bez ssh; plik zamrożony | migawki są wyłącznie na A, więc kolektor nie ma czego sprawdzić lokalnie |
| GUI `tui/new-relation.sh` (68–73) | „Same migawki” = lokalnie na tym hoście | brak opcji „na źródle zdalnym” |

## Runda 1 — zakładanie relacji, rekord, generator, przycinanie

Pliki: `zfs-backup.sh`, `gen-cron.sh`, `lib-record.sh`. Żaden nie jest zamrożony. Recenzent
napisał jednak w REV-148, że **wybór trybu przez generator to osobna akceptacja**, więc ta
runda idzie najpierw do recenzenta jako projekt.

1. **Jawny tryb w rekordzie:** `RUX_MODE=snaponly` (nazwa do potwierdzenia). Każde miejsce,
   które dziś zgaduje tryb z pustego `CLIENT_TARGET`, sprawdza najpierw `RUX_MODE`. Lustro
   pozostaje lustrem, a nowa relacja nigdy nie zostanie odczytana jako lustro.
2. **`add-client --mode=snaponly`:** bez `--target`; `--target` razem z tym trybem to odmowa.
   Bez seeda, bo nie ma czego kopiować. Aktywacja idzie od razu.
3. **Strażnik pokrycia po stronie źródła**, tak jak robi to dziś relacja lokalna
   (`REQUESTED_DATASETS`): dwie relacje „kopia nigdzie” z tym samym datasetem tego samego
   źródła to odmowa.
4. **Generator:** nowa gałąź pull, która renderuje
   `snapget.sh -s -m <prefiks> [-r|-R …] [-L etykieta] [opcje ssh] user@host:dataset`, bez
   bazy i bez flag transferowych. Silnik odrzuca te flagi sam, ale generator nie powinien
   ich nawet emitować.
5. **Przycinanie na źródle:** istniejący mechanizm zdalnej retencji źródła
   (`side = source`, `delsnaps.sh` przez ssh) podpięty dla tej relacji. Przycinania celu nie
   ma, bo nie ma celu.
6. **Minuty poza pvesr:** domyślny harmonogram tej relacji omija minuty, w których zwykle
   startuje pvesr (wielokrotności 5). Prosta reguła, bez czytania konfiguracji pvesr. Admin
   może ją nadpisać. Zmierzone 16.10, 18:30: kolizja w tej samej sekundzie zabrała pvesr jeden
   cykl.
7. **Status i JSON:** tryb `snaponly` widoczny wprost, a „Cel: (brak — tylko migawki na
   źródle)”.

Testy: suita `zfsbackup` (zakładanie, rekord, odmowy) i golden w `gencron` (wyrenderowana
linia),
plus jedno sprawdzenie na labie pve10 → pve9b: relacja założona przez CLI, linia w cronie,
migawka na źródle, brak datasetu na kolektorze.

## Runda 2 — monitor wieku migawek na źródle

**Bez tej rundy relacja nie może iść na produkcję.** To jedyny alarm po migracji gościa i po
cichym zatrzymaniu migawek.

Problem: `check-snap-age.sh` z założenia sprawdza tylko lokalne datasety („monitor ma działać
na hoście, który jest właścicielem harmonogramu”). W tej relacji **właścicielem harmonogramu
jest kolektor**, bo to jego cron robi migawki, a migawki leżą na źródle. Ta sama zasada
przemawia więc za sprawdzaniem źródła z kolektora.

Propozycja: **tryb zdalny w `check-snap-age.sh`** z tymi samymi opcjami ssh co `delsnaps.sh`
(`-p -k -c -K -O`). Odczyt `zfs list` idzie przez klucz parowania i bramkę relacji, która
odczyty przepuszcza. Kody wyjścia zostają bez zmian. Brak połączenia albo odmowa bramki to
UNKNOWN (głośno), nigdy OK. Plik jest zamrożony, więc potrzebny jest **pre-review recenzenta z
`authorizes-frozen: check-snap-age.sh`**.

Alternatywa, odrzucona: linia monitora na samym źródle. Wymaga instalowania crona na A z
kolektora, czego pakiet dziś nie robi, i oddziela alarm od relacji.

Generator emituje linię monitora dla relacji `snaponly` z kolektora, z progiem z profilu,
tak jak dla zwykłej relacji.

Testy: suita `monitor` (tryb zdalny na atrapie ssh: OK, stare, UNKNOWN przy braku połączenia
i przy odmowie bramki) oraz lab: po wyłączeniu linii migawek alarm przychodzi na normalnym
progu.

## Runda 3 — GUI

- `tui/new-relation.sh`: piąta pozycja w kroku „Jaka relacja?”, np. „Same migawki na
  źródle (zdalnie, bez kopii)”. Następny krok to wybór źródła i datasetów jak w backupie,
  bez kroku „Dokąd”.
- `tui/zfs-tui.py` `rel_type()`: wyświetlana nazwa trybu, np. „migawki u źródła”.
- `tui/edit-relation.sh`: edycja źródeł i harmonogramu, bez celu.
- Test na żywo przez ciebie: PuTTY → pve10, `zfs-backup gui`.

## Kolejność i zależności

1. Runda 1 i runda 2 są od siebie niezależne. Runda 2 czeka tylko na pre-review recenzenta
   (plik zamrożony), więc najlepiej wysłać oba projekty do recenzenta naraz.
2. GUI dopiero po rundzie 1 (potrzebuje `--mode=snaponly`).
3. Produkcja (Metropolis) dopiero po rundzie 2, bo bez monitora nie ma alarmu po migracji.

## Decyzje właściciela (2026-10-17)

1. **Nazwa trybu** w CLI i rekordzie: `snaponly`. Zgoda.
2. **Reguła minut:** domyślnie nigdy na wielokrotności 5, admin może nadpisać. Zgoda.
3. **Jedna relacja na dataset źródła, w obrębie jednego kolektora.** Strażnik pokrycia
   widzi tylko rekordy własnego hosta. Relacje innych kolektorów do tego samego źródła są
   dozwolone jak dziś (a<b i a<c to niezależne relacje: różne prefiksy, każda przycina tylko
   swoje).

## Łańcuchy (a<b<c, a<b<>c)

Gdy pierwszym ogniwem jest „kopia nigdzie”, na b nie ma kopii, z której c mógłby pobierać:

- **c pobiera wprost z a**: osobny kolektor, dozwolone (decyzja 3), działa dziś;
- **w klastrze z pvesr c pobiera pasywnie (`-e`) z repliki pvesr na b**: pvesr przenosi na b
  wszystkie migawki z a, także nasze. c nie może zakładać na replice własnych migawek ani
  holdów, bo zepsułyby pvesr (silnik już nie zakłada holdów na datasetach pvesr). Lustro
  b<>c na replice pvesr nie może niczego kasować na b, więc w grę wchodzi tylko pasywne
  pobieranie b→c. **Do zmierzenia na labie przed obietnicą**, w tym zachowanie c po migracji
  gościa na b. Osobny punkt, poza trzema rundami.

## Poza zakresem

- Odzysk dla tej relacji: na kolektorze nie ma kopii. Powrót do migawki na źródle to
  `zfs rollback` admina na A, nie funkcja pakietu.
- Wykrywanie, gdzie jest gość, i strażnik własności: odrzucone przez właściciela.
- Awaryjna relacja jednohostowa na A na czas awarii kolektora: możliwa później, osobny temat.
