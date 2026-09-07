# Brakujące czasowniki warstwy `zfs-backup.sh` — lista dla wątku programisty

Zlecenie właściciela, 2026-09-07: *„Sprawdź raz jeszcze GUI i pakiet pod
względem brakujących czasowników w warstwie zfs-backup i zrób ich listę —
przekazuję to do wątku programisty z dostępem do folderu i github."*

Dokument jest **zleceniem**, nie notatką: każda pozycja ma powód, precedens w
drzewie, kształt wywołania, wymagane odmowy i koszt. Wątek programisty ma
zacząć od sekcji 7.

## 1. Jak ta lista powstała

Inwentarz wzięty z **dyspozytora** (`zfs-backup.sh:12039-12191`), nie z bloku
`usage`. To nie jest formalność: E38 w `IMPLEMENTER-ERROR-LOG.md` powstał
dokładnie z odwrotnego odruchu — twierdzenie o braku wyprowadzone z pomocy
narzędzia, podczas gdy autorytetem jest jego kod. `usage` w tej samej formie
wymienia 11 pozycji, dyspozytor ma 30.

Kontrola do każdej tezy o braku: przed wpisaniem pozycji na listę szukałem
istniejącej implementacji po nazwie funkcji **i** po polu, które miałaby
zapisać. Jedna teza tej kontroli nie przeżyła i została z listy zdjęta:
`list-replicas --json` **już** rozróżnia cztery stany nośnika
(`here`/`available`/`away`/`wrong_medium`, `zfs-backup.sh:5710-5730`), więc
ekran Nośniki nie potrzebuje nowego czasownika.

## 2. Co już jest — 30 czasowników

| grupa | czasowniki |
|---|---|
| tworzenie relacji | `--source=/--target=` (→ `rux_entry`), `local-backup`, `add-client`, `seed`, `activate`, `activate-client`, `final-catchup` |
| stan relacji | `pause-client`, `resume-client`, `disable-client`, `enable-client`, `move-to-client`, `remove-client` |
| łącze i tożsamość | `set-endpoint`, `verify-endpoint`, `set-bandwidth` |
| polityka | `migrate-profile`, `audit-source-retention` |
| odczyt | `status`, `progress` (`--json`), `test` |
| replika i nośnik | `add-replica` (upsert), `list-replicas` (`--json`), `remove-replica`, `run-replicas`, `purge-replica-copy`, `install-media-trigger`, `remove-media-trigger` |
| host | `setup-server` |
| przekazane dalej | `restore` → `zfs-restore.sh` |

Poza tym plikiem, ale w zasięgu GUI: `gen-cron.sh -c FILE` / `--install`
(render i instalacja), `check-snap-age.sh` (monitor, silnik zamrożony),
`zfs-media-gate.sh attach|detach|status`, `clean-relationships.sh`
(audyt/purge), `delsnaps.sh`.

## 3. Czego brakuje — 11 pozycji

| # | czasownik | dla którego ekranu | etap GUI |
|---|---|---|---|
| V1 | `status --json` | główny + panel szczegółów | A |
| V2 | `monitor --json` | Monitor, kolumna werdyktu na liście | A |
| V3 | `show-config KLIENT [--json]` | Polityka, Zakres, macierz | A |
| V4 | `list-profiles [--json]` | picker polityki, filtr zgodności źródła | A |
| V5 | `set-policy KLIENT --pole=…` | edytor polityki | D |
| V6 | `set-tiers KLIENT --dataset=… --templates=…` | macierz dataset × szczebel | D |
| V7 | `set-source-profile KLIENT --profile=…` | retencja niesymetryczna po utworzeniu | D |
| V8 | `set-scope KLIENT --exclude-child=… …` | zakładka Zakres | D |
| V9 | `save-profile --from=… --as=…` | „Klonuj i edytuj" w edytorze polityki | D |
| V10 | `set-defaults` / `set-server-conf` | ekran Kolektor | D |
| V11 | `set-excluded PREFIX --keep=N\|all` | ekran Kolektor | D |

### V1 — `status --json`

`cmd_status` bez argumentu drukuje `printf '%-20s state=%-18s endpoint=%s%s\n'`
(`zfs-backup.sh:~4870`), z nazwanym klientem — blok tekstu. GUI musiałoby to
skrobać, czego §2 pkt 1 dokumentu decyzji zabrania.

Kształt: dokładnie ten, co `progress --json` — jeden obiekt, tablica rekordów,
pola nazwane jak pola rekordu, z którego pochodzą. Minimum na wiersz listy:
`name`, `state`, `active_endpoint`, `paused_local`, `peer_host`, `datasets[]`,
`target`, `profile`, `source_profile`, `pair_label`.

Precedens: `cmd_progress` i `cmd_list_replicas` — dwie implementacje tej samej
konwencji, więc trzecia nie wymyśla niczego.

### V2 — `monitor --json`

Dziś werdykt istnieje wyłącznie jako kod wyjścia pojedynczego wywołania
`check-snap-age.sh` z crona (0/1/2/3). Nie ma nic, co odpowiada na pytanie „jaki
jest werdykt dla każdej relacji na tej maszynie **teraz**", a to jest kolumna na
ekranie głównym i cała treść ekranu Monitor.

**Silnik jest zamrożony i ma taki zostać.** Nowy czasownik ma być czytelnikiem:
przejść po liniach monitora z zainstalowanego crona (albo z wyrenderowanego
configu), wywołać istniejący silnik i zebrać wyniki. Nie wolno mu liczyć wieku
migawek drugą implementacją — to byłaby druga odpowiedź na to samo pytanie.

Musi nieść czwarty stan `UNKNOWN` osobno od OK i od awarii oraz **powód**
słowem, a nie tylko kolorem (§2 pkt 3), w tym stan „relacja wstrzymana", który
silnik już rozróżnia (`-L LABEL`, REV-20260804-045).

### V3 — `show-config KLIENT [--json]`

Bez tego zakładka Polityka nie ma czego wyświetlić, a macierz nie wie, który
dataset bierze które szczeble. Ma zwrócić sekcje configu należące do tej
relacji — wskazują je `MANAGED_DATASETS` i `MANAGED_PRUNE_SCOPE` z rekordu oraz
`pair_label` w sekcjach — z polami: `use_template` per dataset, `recursive`,
pola łącza (`bandwidth`, `compression`, `cipher`), pola zakresu (`passive`,
`exclude_family`, `exclude_child_<n>`), oraz rozwiązane szczeble z ich
`keep`/`retain`/`gfs`/`quiesce`/progami.

Zlecone już częściowo w `OWNER-CONFIG-VERBS-2026-09-06.md` §4 — ta pozycja to
ten sam czasownik, tu tylko z listą pól, których wymaga rozdział 6a.

### V4 — `list-profiles [--json]`

Nie istnieje. Picker polityki musi pokazać opis, a filtr zgodności strony
źródłowej (rozdział 6a) musi **przed** wyborem wiedzieć, które profile mają te
same rodziny, co profil kolektora.

Na profil: `name`, `description` (z sekcji `[profile]`), `shape` (jedna rodzina
vs rodzina na szczebel), `mechanism` (`flat`/`gfs`/`age`), `tiers[]` z
`pattern`, `keep`/`retain`, `quiesce`, oraz **sygnatura rodzin** liczona tą samą
funkcją, której używa guard: `profile_fragment_patterns`
(`zfs-backup.sh:~1673`). Druga implementacja sygnatury dałaby GUI listę
niezgodną z odmową, którą sam produkt wystawia.

### V5 — `set-policy KLIENT [--pole=wartość …] [--preview] [--yes]`

Już zlecone w `OWNER-CONFIG-VERBS-2026-09-06.md` (wycena 4–6 dni). Bez zmian;
wymienione tu, żeby lista była kompletna.

### V6 — `set-tiers KLIENT --dataset=ŚCIEŻKA --templates=h,d,w,m`

To **nie** jest pole polityki, tylko wiązanie: `use_template` na `[dataset:]`.
`set-policy` go nie obejmuje i obejmować nie powinien — polityka mówi „ile i
jak", wiązanie mówi „kto z tego korzysta".

Wymagane odmowy: nazwa szczebla spoza tych, które definiuje aktywny profil;
dataset spoza `MANAGED_DATASETS` tej relacji; pusta lista (to znaczy „dataset
bez zadania" — musi być możliwa, ale powiedziana wprost przez `--none`, a nie
przez pustą wartość, bo pusta wartość to najczęściej literówka).

### V7 — `set-source-profile KLIENT --profile=NAME`

`--source-profile` działa **tylko przy tworzeniu**. `migrate-profile` celuje w
CONFIG jako całość (`--config=PATH`), nie w jedną relację, i nie zna strony
źródłowej. Więc „po tygodniu chcę na źródle trzymać mniej" nie ma dziś
czasownika — tylko ręczną edycję sekcji `src_`.

Musi wołać `assert_source_profile_families` — ta sama odmowa, co przy
tworzeniu: wolno różnić się ILOŚCIĄ, nie RODZAJEM.

Musi też uszanować REV-20260811-107: retencja źródła zredagowana ręcznie nie
znika po cichu. Odmowa albo `--force` z wypisaniem różnicy — do rozstrzygnięcia
przez recenzenta, ale nie milczące nadpisanie.

### V8 — `set-scope KLIENT [--exclude-child=REGEX] [--drop-exclude-child=REGEX] [--exclude-family=LISTA] [--passive=yes|no]`

Pola zakresu są dziś wyłącznie ręczne. Numerowanie `exclude_child_1..n` **bez
dziur** jest zadaniem pisarza — `gen-cron` odmawia przy dziurze, bo wpisy
powyżej są po cichu gubione (`gen-cron.sh:~1034`), więc GUI nigdy nie może
podać numeru.

Granica, którą ten czasownik ma egzekwować: zawężenie jest jednostronne,
poszerzenie poza podpisany zakres źródła nie. Jeżeli usunięcie wykluczenia
wyprowadza żądanie poza to, co źródło podpisało, czasownik odmawia i nazywa
`--commit-scope` na źródle.

### V9 — `save-profile --from=NAME --as=NAME2` (+ zapis szczebli)

Bez tego edytor polityki musiałby sam pisać pliki INI, czyli nosić drugą kopię
schematu pól — wbrew §2 pkt 2. Profil fabryczny jest plikiem pakietu: klon, nie
edycja.

Nazwa **wyprowadzana z zawartości**, nie przyjmowana dowolnie:
`profiles/README.md` mówi „nazwa to retencja", a `test/profiles` to egzekwuje
przeciw wyrenderowanej linii `delsnaps`. Czasownik ma tę nazwę wyliczyć i
odmówić, gdy podana jej przeczy.

### V10 — `set-defaults --pole=…` i `set-server-conf --pole=…`

Ekran Kolektor: `[defaults]` (`host_label`, `repo_dir`, `notify_script`,
`warn_script`, `digest_script`, `cron_log`) i `server.conf` (`DEFAULT_TARGET`,
`CRON_CONFIG`). Dziś jedno i drugie tylko ręcznie.

Lista pól ma być **wyprowadzona** z `_allow_fields defaults` w `gen-cron.sh`, a
nie przepisana — przepisana rozjedzie się przy pierwszym nowym polu.

### V11 — `set-excluded PREFIX --keep=N|all`

Sekcje `[excluded:<prefix>]` — ile z cudzej, zarezerwowanej rodziny prune ma
zostawić w spokoju. Ustawienie **kolektora**, nie relacji.

Klasa destrukcyjna: obniżenie z `all` do liczby na `__replicate_` może pozwolić
skasować migawkę spod `pvesr` i nieodwracalnie zerwać łańcuch replikacji.
Wymaga potwierdzenia i ostrzeżenia nazywającego skutek, nie samego `--yes`.

## 4. Reguły wspólne — obowiązują każdą pozycję

1. **Czytelniki**: kontrakt `progress --json`. Jeden obiekt, tablica rekordów,
   pola nazwane jak pola źródłowe. Kontrakt wpisany do `test/deps.conf`, suita z
   kontrolą ujemną per pole.
2. **Pisarze**: wzorzec `cmd_set_bandwidth` — kopia robocza obok configu, `cp -p`,
   edycja, **walidacja przez wyrenderowanie prawdziwym `gen-cron`**, odmowa z
   oryginałem nietkniętym, dopiero potem podmiana i `--install`. Żaden nowy
   czasownik nie powtarza reguły, którą `gen-cron` już zna.
3. **Zapis pól**: `set_or_remove_section_field` — istnieje, jest generyczny,
   przepuszcza resztę pliku przez `awk`, więc komentarze i ręcznie dopisane
   sekcje przeżywają, a `mv_preserving_mode` trzyma uprawnienia.
4. **Dane to dane**: config, manifest, rekord i nazwa datasetu nigdy nie idą
   przez `source`/`eval`.
5. **Zamrożone silniki** (`check-snap-age.sh`, `delsnaps.sh`) zmienia się
   wyłącznie na jawne polecenie właściciela. V2 jest czytelnikiem silnika.
6. Każda pozycja kończy się regresją dyskryminującą i kontrolą ujemną wobec SHA
   sprzed zmiany; `./test/impact.sh` LISTUJE wymagane suity, `--verify`
   uruchamiany goło (E37 — nigdy za `|`).

## 5. Kolejność i zależności

- **A (dane, nic nie zapisuje):** V1, V2, V3, V4. Nie zależą od niczego i
  odblokowują etapy B i C GUI. To jest właściwy pierwszy commit.
- **D (zapis):** V5 (już zlecone) → V6, V7, V8 → V9 → V10, V11.
  V6–V8 dziedziczą walidator i wzorzec bezpiecznej edycji po V5, więc po nim są
  tanie; przed nim każde z osobna musiałoby zbudować to samo rusztowanie.

Wycena, kalibrowana na `set-bandwidth` i `set-endpoint` (każdy wylądował w
jednym commicie jednego dnia) oraz na wycenie V5:

| paczka | zawartość | dni |
|---|---|---|
| A | V1–V4 | 3–4 |
| D1 | V5 (zlecone osobno) | 4–6 |
| D2 | V6, V7, V8 po V5 | 3–4 |
| D3 | V9 | 2–3 |
| D4 | V10, V11 | 2 |

## 6. Czego świadomie nie ma na tej liście

- **`restore`** — osobny dokument decyzji, klasa destrukcyjna.
- **`remove-source`** i **poszerzanie zakresu** — poza zleceniem V5 i tak samo
  poza tym: poszerzenie jest operacją dwumaszynową, bo dowodem jest plik zakresu
  po stronie źródła i jego podpis.
- **Nośniki** — `list-replicas --json` wystarcza, sprawdzone (sekcja 1).
- **Repliki** — `add-replica` jest upsertem, więc tworzenie i edycja już są.
- **`gen-cron.sh` `usage` nie wymienia `[replica:]`** — znaleziona wada
  produktowa, ale to poprawka dokumentacji w pliku, nie czasownik.

## 7. Start dla wątku programisty

```bash
git fetch origin main && git log --oneline -1 origin/main
sed -n '1,120p' docs/internal/IMPLEMENTER-ERROR-LOG.md      # sekcja 1, obowiązkowo
cat docs/internal/reviews/REVIEW_LEDGER.md | grep -v CLOSED  # czy coś jest OPEN | Claude
sed -n '/^## 6a\./,/^## 7\./p' docs/discussions/OWNER-GUI-DECISION-2026-09-04.md
cat docs/discussions/OWNER-CONFIG-VERBS-2026-09-06.md        # V5, zlecone wcześniej
grep -n 'cmd_progress\|cmd_list_replicas' zfs-backup.sh      # wzorzec czytelnika
grep -n 'cmd_set_bandwidth' zfs-backup.sh                    # wzorzec pisarza
./test/impact.sh                                             # co trzeba uruchomić
```

Pierwszy commit: **paczka A**, w kolejności V1 → V3 → V4 → V2. V2 jest ostatnie
w paczce, bo jest jedyne, które dotyka zamrożonego silnika jako czytelnik i
najlepiej robić je, gdy konwencja `--json` jest już utrwalona przez trzy
pozostałe.
