# Etap 2 — kontrakt i testy przed kodem

Bramka z `REV-20260807-060`: Etap 2 nie powstaje, dopóki kontrakt i lista testów
nie zostaną zatwierdzone. To jest ten dokument. **Zero kodu.**

Trzy zmiany w silnikach transferu, jedna kaskada testów, osobne commity.

---

## 2.1 Sufiks nazwy snapshotu liczony raz na przebieg

**Dziś:** `create_snapshot()` liczy `$(date '+%Y-%m-%d_%H-%M-%S')` **osobno dla
każdego datasetu** ([snapsend.sh:862](../../snapsend.sh)). Poddrzewo
przekraczające granicę sekundy dostaje **różne nazwy**, więc przebiegu nie da
się skorelować.

Zmierzone: `atomic` i `flat -q` już korelują (jedna nazwa, jeden `creation` —
na 11.11 wszystkie pięć datasetów miało `creation 1786107661`). `flat` bez `-q`
nie koreluje.

**Kontrakt:** sufiks wyliczany raz, przed pętlą, i podawany do
`create_snapshot`. Format nazwy **bez zmian**. `atomic` i `-q` bez zmian.

**Czego to NIE obiecuje:** wspólna nazwa dowodzi wspólnego **przebiegu**, nie
wspólnego punktu w czasie. Pod `flat` bez `-q` snapshoty nadal powstają jeden po
drugim. Restore ma to raportować, a nie udawać, że trzy tryby są równoważne.

## 2.2 Dokładnie jedna deklaracja rekursji na wywołanie

**Dziś:** `-r -R` naraz nie jest odrzucane — wygrywa ostatnia flaga. Generator
odrzuca to w configu, CLI nie.

**Kontrakt (REV-054 A4, dosłownie):**

- deklaracje: `-r`, `-R`, `--recursive=atomic|flat|no`;
- **co najwyżej jedna** na wywołanie;
- druga to błąd, **nawet gdy powtarza ten sam tryb** lub miesza formę krótką z długą;
- `--recursive=no` jest pełnoprawną deklaracją, nie brakiem flagi;
- po `--` długie opcje nie są interpretowane;
- zła wartość zawodzi zamknięcie.

Reguła jednej deklaracji **pochłania** osobny punkt „`-r -R` = odmowa".

## 2.3 Długie opcje

`getopts` nie obsługuje długich opcji, więc w `snapsend`/`snapget` potrzebny
jest pre-pass przed pętlą. `delsnaps`/`check-snap-age` mają własne pętle — tam
to jedna gałąź `case`.

**Generowany cron zostaje przy krótkich flagach.** Uzasadnienie:
zmiana formy emisji przepisałaby każdy crontab we flocie i unieważniła dowód
bajtowej równości, a `cron2conf` musiałby przyjmować dwie pisownie jednej
decyzji — chorobę, którą REV-054 wyleczyła w configu.

---

## Testy, które to wymuszą

Kaskada jedna, ale kontrakty osobne — commit na zmianę.

### 2.1 — korelacja przebiegu
| przypadek | oczekiwane |
|---|---|
| `flat` na poddrzewie ≥2 datasetów | **wszystkie** nazwy identyczne |
| to samo, przebieg przekraczający granicę sekundy (zaślepiony `date`) | nadal identyczne |
| `atomic` | bez zmian wobec dziś |
| `flat -q` | bez zmian wobec dziś |
| format nazwy | bajt w bajt jak dziś |

Kontrola negatywna: zaślepka `date` zwracająca rosnące wartości **musi** dziś
dać różne nazwy, a po zmianie jedną.

### 2.2 — jedna deklaracja
| wejście | oczekiwane |
|---|---|
| `-r` / `-R` / `--recursive=atomic` / `=flat` / `=no` | przyjęte |
| `-r -R` | **odmowa** |
| `-r -r` | **odmowa** (ten sam tryb, wciąż dwie deklaracje) |
| `-r --recursive=atomic` | **odmowa** (mieszana forma) |
| `--recursive=no -r` | **odmowa** — przypadek, który w mojej pierwotnej propozycji zwijał się cicho do `-r` |
| `-m --recursive=flat` | przyjęte, to argument opcji `-m` |
| `-- --recursive=flat` | przyjęte jako pozycyjny |
| `--recursive=ture` | **odmowa** |

### 2.3 — długie opcje
| | |
|---|---|
| `--recursive=atomic` ≡ `-r`, `=flat` ≡ `-R` | identyczne zachowanie |
| `--recursive` w `delsnaps`/`check-snap-age` ≡ `-R` | identyczne |
| wygenerowany cron | **bajt w bajt jak dziś** na wszystkich czterech hostach |
| `cron2conf` round-trip | bez zmian |

### Wspólne
- `test/snapsend`, `test/delsnaps`, `test/monitor`, `test/cron`, `test/cron2conf`,
  `impact.sh --verify`;
- `test/scenarios` **na prawdziwym ZFS-ie** — dziś złapało kontrakt, którego
  suita jednostkowa nie mogła;
- kontrola negatywna dla każdej z trzech zmian, raportowana **obiema** liczbami;
- przebieg na hoście **jako konto delegowane**, nie tylko root.

---

## Czego w Etapie 2 nie ma

Kompresji, catch-upu, restore'u, profili, zmian w `gen-cron` poza tym, co
wymusi punkt 2.3. Jeżeli któraś z tych rzeczy okaże się potrzebna, to jest
sygnał, że kontrakt jest zły — nie powód, żeby poszerzyć plaster.

## Po Etapie 2

Zamrożenie silnika (Etap 3) wymaga zapisanej definicji: które pliki są
zamrożone i że ich zmiana wymaga recenzji **przed** implementacją. Bez tego
„freeze" jest życzeniem.
