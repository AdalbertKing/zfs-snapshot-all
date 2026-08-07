# Etap 2 — kontrakt i testy przed kodem

Bramka z `REV-20260807-060`: Etap 2 nie powstaje, dopóki kontrakt i lista testów
nie zostaną zatwierdzone. To jest ten dokument. **Zero kodu.**

Trzy zmiany w silnikach transferu, osobne commity, i **osobna weryfikacja dla
każdej** — dobierana do tego, od czego dana zmiana faktycznie zależy (REV-066).

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

**Dziś — SPROSTOWANIE (2026-08-07, przy implementacji).** Zdanie, które tu
stało — „`-r -R` naraz nie jest odrzucane, wygrywa ostatnia flaga" — było
**nieprawdziwe**. Zmierzone na `a51e09f`: oba silniki odrzucają `-r -R`
w obu kolejnościach, i robią to od dawna (`snapsend.sh:1501`,
`snapget.sh:1512`). Kontrola negatywna to potwierdza — te przypadki
**przechodzą** na kodzie sprzed zmiany.

Prawdziwa luka jest węższa: **powtórzona deklaracja tego samego trybu**
(`-r -r`, `-R -R`) przechodzi po cichu. To jedyne, co Etap 2.2 dokłada dla
flag krótkich; reszta reguły z REV-054 A4 dotyczy pisowni długich i wchodzi
z Etapem 2.3.

Zapisuję to zamiast po cichu poprawić, bo recenzent zatwierdził plan
zawierający tę przesłankę (REV-060), a zakres 2.2 wyszedł przez to mniejszy,
niż był wyceniony.

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

Kontrakty osobne, commit na zmianę, weryfikacja per zmiana — patrz sekcja
poniżej tabel.

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
| wygenerowany cron | **bajt w bajt jak dziś** — sprawdzane tylko wtedy, gdy graf wskaże `gen-cron.sh` jako tknięty |

### Weryfikacja — dobierana do zależności, nie jedna kampania na wszystko

REV-066 słusznie odrzuciła moją pierwotną listę „wspólne dla wszystkich trzech".
Sedno zarzutu, i zgadzam się z nim: dzień pokazał, że **duża liczba zielonych
testów bywa słabym dowodem**, ale to samo działa w drugą stronę — **przebieg na
żywym hoście na ścieżce, która nie potrafi rozróżnić zmiany, nie jest mocniejszym
dowodem, tylko droższym**.

Pytanie rozstrzygające dla każdej zmiany brzmi: **od jakiej właściwości
środowiska ona zależy?**

| | od czego zależy | co to rozróżnia |
|---|---|---|
| 2.1 sufiks | od rzeczywistego czasu powstawania snapshotów | **tylko prawdziwy ZFS** |
| 2.2 jedna deklaracja | od niczego — to normalizacja argv | **nic w środowisku**; host nie doda dowodu |
| 2.3 długie opcje | od tego, czy **wdrożony** skrypt je rozumie | **jedno** wywołanie jako konto delegowane |

#### 2.1 — sufiks i korelacja przebiegu

- ukierunkowana regresja `snapsend`: tryb `flat` na ≥2 datasetach, plus zaślepka
  `date` przekraczająca granicę sekundy;
- kontrola negatywna: na dzisiejszym kodzie przypadek korelacji **musi paść**,
  a przypadki nietknięte przejść — obie liczby raportowane;
- suity wskazane przez `impact.sh` dla faktycznego diffu;
- **jeden** scenariusz na prawdziwym ZFS-ie dowodzący korelacji end to end —
  bo ta właściwość istnieje wyłącznie w rzeczywistym zachowaniu snapshotów;
- konto delegowane **tylko jeśli** zmieniona ścieżka jest pod nim wykonywana.

#### 2.2 — jedna deklaracja rekursji

- testy parsera dla obu silników transferu, każda pisownia i każdy konflikt
  z tabeli wyżej;
- kontrola negatywna wobec obecnego kodu;
- suity wybrane przez graf, nic ponadto;
- **bez kampanii na ZFS-ie i bez przebiegu na hoście.** To jest normalizacja
  argumentów; `-r -r` albo `--recursive=ture` zachowa się na produkcyjnym hoście
  identycznie jak lokalnie. Przebieg na żywo dowiódłby tu wyłącznie tego, że
  ssh działa.

#### 2.3 — długie opcje

- testy równoważności dla skryptów, które faktycznie dostają aliasy;
- kontrola negatywna: stara wersja **nie rozumie** nowej pisowni, a stara
  krótka forma działa bez zmian;
- suity wybrane przez graf;
- **jedno** wywołanie na hoście jako konto delegowane — bo tylko ono dowodzi, że
  **zainstalowana** kopia skryptu przyjmuje nową pisownię. Lokalny przebieg tego
  nie rozstrzyga: wdrożony plik może być starszy. To jest tani, rozróżniający
  dowód, w przeciwieństwie do kampanii na czterech hostach.
- **bajtowa równość crona: tylko jeśli graf ją wskaże.** Jeżeli `gen-cron.sh`
  nie jest tknięty, nie uruchamiam `cron`/`cron2conf` po to, żeby dowieść, że
  nietknięty plik się nie zmienił.

#### Wspólne — naprawdę wspólne

`./test/impact.sh --verify`. Tyle. Waliduje sam graf, więc obowiązuje zawsze.

#### Kiedy zakres rośnie

Eskalacja do szerszej kampanii jest **warunkowa, nie domyślna**: gdy
implementacja wyjdzie poza normalizację argumentów, gdy dotknie
`gen-cron.sh`/`lib-*`, albo gdy `impact.sh` wskaże krawędź, której ten dokument
nie przewidział. Wtedy zakres bierze się z grafu, nie z ostrożności.

## Czego w Etapie 2 nie ma

Kompresji, catch-upu, restore'u, profili, zmian w `gen-cron` poza tym, co
wymusi punkt 2.3. Jeżeli któraś z tych rzeczy okaże się potrzebna, to jest
sygnał, że kontrakt jest zły — nie powód, żeby poszerzyć plaster.

## Po Etapie 2

Zamrożenie silnika (Etap 3) wymaga zapisanej definicji: które pliki są
zamrożone i że ich zmiana wymaga recenzji **przed** implementacją. Bez tego
„freeze" jest życzeniem.
