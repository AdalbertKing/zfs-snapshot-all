# Uzgodnienia: system profili retencji/rekurencji

Zapis decyzji podjętych w rozmowie właściciel ↔ implementer, 2026-08-04, po
zamknięciu kampanii A–J (REV-20260804-044, ACCEPTED). Dokument rośnie w
trakcie dyskusji; **nie jest** odpowiedzią na recenzję ani projektem do
implementacji. Kolejność: dyskusja → uzgodniony stan → implementacja → testy.

Punkt wyjścia (słowa właściciela): dzisiejszy zestaw (`standard_hourly` +
GFS-drabinka `keep_hourly/daily/weekly/monthly`, wstrzykiwany identycznie
każdemu klientowi przez `emit_client_sections`) to **profil domyślny**.
Chcemy umieć dodawać kolejne nazwane profile (np. retencja płaska bez GFS,
inne liczby typu 24/30/12, z rekurencją lub bez), wybierane per klient, bez
przepisywania silnika `gen-cron.sh` — silnik (`[template:]`/`use_template`/
`gfs=`/`recursive=`) już dziś wyraża wszystko, czego to wymaga.

---

## P1. Profile jako pliki-szablony w trackowanym `profiles/`

Nie kod zaszyty w `zfs-backup.sh` (jak dziś `STANDARD_TEMPLATE_*`/
`KEEP_TEMPLATE_*`). Dzisiejszy hardcoded zestaw staje się plikiem
`profiles/default.conf` — zero zmiany zachowania dla istniejących klientów.
Nowy profil = nowy plik, bez zmiany w `zfs-backup.sh`.

## P2. `--profile NAME`, domyślnie `default`

Na komendach **`zfs-backup.sh add-client`/`activate-client`** — nie na
`deploy.sh --pair`. Uzasadnienie: parowanie (`deploy.sh`) zajmuje się
kluczami SSH, delegacją ZFS i zakresem datasetów; nic nie wie o retencji.
Retencja/profil to wyłącznie to, jak **kolektor** generuje sobie własny
config przez `emit_client_sections` — nie dotyczy strony peera. Brak
podanego `--profile` = zachowanie identyczne z dzisiejszym, dla każdego
istniejącego i nowego klienta.

## P3. Wybór zapisany trwale w manifeście klienta

Nowe pole, obok istniejących `PEER_SAVED_MODE`/`PEER_SAVED_TARGET`:
`PEER_SAVED_PROFILE`. Bez tego kolejna regeneracja (`activate-client`,
przyszły odpowiednik `migrate-profile`) nie wiedziałaby, jaki profil
odtworzyć — ten sam błąd klasy "cichej zmiany zachowania", jaki już raz
złapano przy innych polach manifestu.

## P4. Osobny katalog na profile własne/eksperymentalne, POZA białą listą `.gitignore`

Nazwa robocza: `profiles.local/`. Wzorzec: `cron-configs/` — ścieżka
celowo nieodkryta w `.gitignore` (repo działa na białej liście: `*` potem
jawne `!ścieżka`), więc niewidoczna dla `git status --porcelain` i nigdy nie
blokuje `update-control.sh --self-update`. To nie kosmetyka: `update-control.sh`
odmawia CAŁEJ aktualizacji, gdy cokolwiek w repo jest "dirty" — w tym
pojedynczy nieskomitowany plik. Ręczna kopia szablonu do edycji, zostawiona
w trackowanym katalogu, cicho zamroziłaby self-update na tym hoście.

## P5. Kolejne nazwane profile — zaplanowane, nie w tym etapie

Na razie istnieje tylko `default` jako plik. `flat-24-30-12`, `no-recursion`
i inne warianty projektujemy później, osobno.

---

## Ustalenia techniczne wynikające z powyższych

### T1. Kolizja nazw template'ów między klientami jednego hosta

Nazwy sekcji `[template:...]` są dziś globalne per host (`standard_hourly`,
`keep_hourly` itd. — współdzielone przez wszystkich klientów na tym samym
hoście). Jeśli dwóch klientów na jednym kolektorze wybierze różne profile,
nazwy template'ów muszą się rozejść (namespace per profil albo per klient),
inaczej druga generacja nadpisze sekcje pierwszej. Do rozstrzygnięcia przed
implementacją P1/P2.

### T2. `.gitignore` wymaga jawnego wpisu dla `profiles/`, NIE dla `profiles.local/`

`profiles/` (śledzone, wysyłane przez git do całej floty) potrzebuje
`!profiles/` + `!profiles/**`, tak jak dziś `test/`/`docs/`. `profiles.local/`
musi pozostać poza białą listą — to jest cały mechanizm bezpieczeństwa z P4.

### T3. Miejsce implementacji

`zfs-backup.sh` (`emit_client_sections`, `cmd_add_client`,
`cmd_activate_client`, manifest read/write). `deploy.sh` nie jest ruszany.

### T4. Domyślność jako warunek zerowego ryzyka migracji

`--profile` nieobecny → `default` → identyczne zachowanie jak dziś. Żaden
istniejący klient nie wymaga akcji przy wdrożeniu tej funkcji. Migracja na
inny profil pozostaje zawsze jawną, osobną decyzją operatora (tak jak dziś
`migrate-profile`), nigdy czymś dziejącym się przy okazji.
