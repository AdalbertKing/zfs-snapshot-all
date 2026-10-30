# Repo wydań: hosty pobierają tylko pakiet, reszta prywatna (projekt do decyzji, 2026-10-24)

Status: **PROJEKT, nic nie kodowane, hosty nietknięte.** Polecenie właściciela 2026-10-24: „robić” (plan
odchudzenia pakietu ściąganego na hosty i ukrycia reszty w repo prywatnym). Wiąże się z decyzją z tego samego dnia:
repo `AdalbertKing/zfs-snapshot-all` ma być prywatne do wydania 1.0, a adresy sieci firm (około 1000 w testach,
statusie i recenzjach) znikną przy wydaniu.

## 1. Dziś (inwentarz z drzewa, main 2026-10-24)

- Każdy host co godzinę robi `update-control.sh --self-update` (cron z `deploy.sh:5639-5644`, minuta z
  `update.time`; bez wdrożonej kopii update-control -- `deploy.sh --self-update`, który ją wywołuje): `git fetch origin main`, odmowa przy zmianach lokalnych, zapis `previous-revision`,
  `git merge --ff-only FETCH_HEAD`, potem `deploy.sh` (`update-control.sh:230-281`). Konta delegowane mają własny
  cron o stałej minucie :15, zwykły `git pull --ff-only origin main` bez holdu i bez `previous-revision`
  (`deploy.sh:7868`), a ich kopia jest klonem checkoutu roota (`git clone $SCRIPT_DIR`, `zfs-backup.sh:9835`)
  -- ich `origin` to ścieżka lokalna, nie GitHub.
- Adres repo: w `deploy.sh` -- `REPO_URL` ze środowiska (`deploy.sh:81`), inaczej `origin` checkoutu
  (`deploy.sh:97-98`), dopiero na końcu wpisany na sztywno `https://github.com/AdalbertKing/zfs-snapshot-all.git`
  (`deploy.sh:99`). `prepare-source` bierze `origin` kolektora, a bez niego ten sam adres na sztywno
  (`zfs-backup.sh:14556-14557`), i klonuje źródło z tego adresu (bundle, gdy się nie da). Wniosek: o tym,
  skąd host się aktualizuje i skąd klonuje źródła, decyduje `origin` checkoutu, nie stała w kodzie.
- `--rollback` i `update-hold` używają zwykłych SHA w plikach stanu (`/root/.zfs-snapshot-all-update-state`);
  rollback do rewizji, której nie ma w klonie, jest odrzucany (`update-control.sh:293`).
- `--version` pokazuje `git rev-parse --short HEAD` (`zfs-backup.sh:21702`, `deploy.sh:445`); check-source
  pokazuje rewizję źródła (tylko do wyświetlenia, nic jej nie porównuje).
- Na host trafia całe repo: 695 plików `docs/`, 343 `test/`, ~30 MB historii. Do działania potrzeba 63 plików
  (lista w §3: skrypty, `hostscripts/`, `profiles/`, `tui/`). Kod nic nie czyta z `docs/` ani `test/` (tylko wspomina ścieżki w komunikatach).

**Po przełączeniu repo na prywatne bez zmian:** `fetch` przez HTTPS bez tokenu przestaje działać -- wszystkie
hosty (lab i produkcja) przestają się aktualizować, po cichu (błąd tylko w `git-pull.log`).

## 2. Propozycja

Dwa repozytoria:

| repo | widoczność | co | kto pisze |
|---|---|---|---|
| `AdalbertKing/zfs-snapshot-all` (dzisiejsze) | prywatne | wszystko: kod, testy, recenzje, status, CI | jak dziś |
| `AdalbertKing/zfs-snapshot-all-release` (nazwa do decyzji) | publiczne | tylko pakiet do działania (§3) | tylko skrypt publikacji |

- Hosty śledzą `main` repo wydań. Jego historia rośnie liniowo i **nigdy nie jest przepisywana** (warunek
  `merge --ff-only` na hostach). Jeden commit wydania = stan pakietu z jednej rewizji dev; plik `RELEASE-OF`
  w korzeniu podaje pełny SHA dev, wiadomość commita też.
- Repo wydań jest od razu przyszłym repo publicznym 1.0: czysta historia od pierwszego commita, bez testów,
  recenzji i adresów IP firm, z README i LICENSE.

## 3. Pakiet (lista plików wydania)

- skrypty w korzeniu: `zfs-backup.sh`, `deploy.sh`, `update-control.sh`, `gen-cron.sh`, `snapsend.sh`,
  `snapget.sh`, `delsnaps.sh`, `check-snap-age.sh`, `zfs-job.sh`, `zfs-media-gate.sh`, `zfs-pair-gate.sh`,
  `zfs-quiesce-helper.sh`, `zfs-restore.sh`, `clean-relationships.sh`, wszystkie `lib-*.sh`;
- katalogi: `hostscripts/`, `profiles/`, `tui/` bez `tui/lang/build.py` i `tui/lang/en.extra.json` (narzędzia
  budowy katalogu);
- dokumentacja użytkownika: `docs/pl/`, `docs/en/`, `README.md`, `LICENSE`;
- `RELEASE-OF` (generowany).

Poza wydaniem: `test/`, `docs/internal/`, `docs/project/`, pozostałe `docs/*`, `.github/`, `.claude/`,
`AGENTS.md`, `CLAUDE.md`, `PAIRING-DESIGN.md`, `LVM-TWIN-DESIGN.md`. Komunikaty, które wskazują pliki spoza
wydania (`zfs-backup.sh:817-818`, `gen-cron.sh:1174`, `:2348`), dostają odnośnik do `docs/pl|en` albo zostają
bez ścieżki.

Lista żyje w jednym pliku w repo dev (`release/MANIFEST`), a test pilnuje dwóch rzeczy: każdy plik
źródłowany/wywoływany przez skrypty z listy też jest na liście; żadna linia wykonywalna (poza komentarzami) w
plikach z listy nie odwołuje się do `test/` ani do `docs/` spoza `docs/pl|en`. `.gitignore` jest białą listą --
katalog `release/` trzeba do niej dopisać (`!release/`, `!release/**`).

## 4. Publikacja

`release/publish.sh <SHA dev>` (tylko w repo dev): `git archive` plików z `MANIFEST` dla tej rewizji ->
wypakowanie do klona repo wydań -> `RELEASE-OF` -> commit „release of <SHA>” (pusty diff = brak commita) ->
`git push` (zwykły, nigdy `--force`). Uruchamiane:

- **automatycznie** z CI po zielonym main (krok w workflow; potrzebny klucz/token do zapisu w repo wydań jako
  sekret repo dev -- zakłada właściciel), albo
- **ręcznie** tym samym poleceniem.

Do decyzji: automat po każdym zielonym main (hosty jak dziś dostają zmiany w ciągu godziny) czy ręcznie,
paczkami (wolniej, ale świadomie).

## 5. Zmiany w kodzie (jeden PR przed przepięciem)

1. Adres na sztywno (`deploy.sh:99`, `zfs-backup.sh:14557`) i README = repo wydań. To tylko ostatnia deska:
   na hostach decyduje `origin` checkoutu, więc właściwą zmianą jest przepięcie (pkt 3); `prepare-source` po
   przepięciu kolektora sam klonuje z repo wydań. Checkout dev zostaje przy swoim `origin`.
2. `--version`: rewizja wydania i, gdy jest `RELEASE-OF`, rewizja dev (`zfs-backup.sh:21702`, `deploy.sh:445`).
3. **Przepięcie checkoutu** -- nowa czynność (np. `update-control.sh --switch-origin=URL`), bo historie są
   różne i `--ff-only` się nie uda: hold -> `remote set-url origin URL` -> `fetch` -> sprawdzenie, że
   `RELEASE-OF` w nowym repo to rewizja nie starsza niż obecna -> `reset --hard origin/main` -> `deploy.sh` ->
   zdjęcie holdu. To samo dla kopii kont delegowanych: ich `origin` to checkout roota, więc po przepięciu roota
   wystarczy u konta `fetch` + `reset --hard origin/main` -- i to KONIECZNIE w tym samym kroku, bo cron konta
   to zwykły `git pull --ff-only` bez holdu (`deploy.sh:7868`) i na różnej historii zacznie się po cichu
   wywracać. Przy okazji: cron konta dostaje ten sam hold i tę samą minutę co root. `previous-revision` czyszczony: rollback przez granicę przepięcia nie ma
   sensu (stara rewizja nie istnieje w nowym repo) i jest odrzucany jak dziś.
4. `release/MANIFEST`, `release/publish.sh` i test listy (§3).

## 6. Kolejność

1. Właściciel zakłada puste publiczne repo wydań (nazwa) i -- przy automacie -- klucz do zapisu.
2. PR z §5, CI, scalenie.
3. Pierwsza publikacja; porównanie drzewa wydania z checkoutem dev (te same pliki z listy, te same bajty).
4. **Lab** (pve9, pve9b, pve10, pve11; root i konta): przepięcie, potem jeden cykl godzinowej aktualizacji po
   kolejnej publikacji, `--version`, `rollback` w obrębie nowego repo, `prepare-source` na nowym źródle.
5. **Produkcja** (6 instalacji: 4 checkouty roota i 2 konta `zfsbackup` na Metropolis): plan krok po kroku i
   zgoda właściciela na każdy krok zmieniający hosty.
6. Dopiero teraz właściciel przełącza repo dev na prywatne; sprawdzenie, że wszystkie instalacje dalej się
   aktualizują (`git-pull.log`, `--version`).

## 7. Ryzyka i koszty

- Repo dev prywatne = CI na limicie minut GitHub Actions dla repo prywatnych (darmowe 2000 min/mies.; dziś każdy
  push to kilkanaście równoległych zadań). Do sprawdzenia przed krokiem 6, inaczej CI stanie albo zacznie
  kosztować.
- Host, którego nie przepięto przed krokiem 6, przestanie się aktualizować po cichu -- dlatego lista instalacji
  z §6.5 i odczyt `git-pull.log` na każdej po kroku 6.
- Opóźnienie: przy publikacji ręcznej hosty dostają poprawki dopiero po publikacji.

## 8. Pytania do właściciela

1. Nazwa repo wydań (`zfs-snapshot-all-release`, czy od razu docelowa nazwa publiczna, np. `zfs-snapshot-all`
   pod inną organizacją).
2. Publikacja automatyczna po zielonym main czy ręczna.
3. README i LICENSE w repo wydań już teraz (repo jest publiczne od początku) czy minimalne do 1.0.

## 9. Stan po przepięciu i sprzątanie starej historii (2026-10-30, do recenzji)

Status: **PROPOZYCJA, nic nie zrobione na hostach.** Polecenie właściciela 2026-10-30: najpierw recenzent.

### 9.1 Zmierzone 2026-10-30

- Wydanie 1.0.5 = zfsbackup `3d15bc4`: 96 plików, 6,0 MB po rozpakowaniu, świeży klon pobiera 2,0 MB
  (`size-pack`, 40 commitów). Żaden plik wydania nie odwołuje się do `AdalbertKing/zfs-snapshot-all`.
- Wszystkie osiągalne instalacje (pve1 i pve2 na 28.x, pve0 i pve1 na 11.x, pve9, pve10, pve11; root i konto
  `zfsbackup`) mają `origin` = zfsbackup i `main` = `3d15bc42`. pve9b (10.98.0.2) nieosiągalny, niezmierzony.
- Kod nie ma czynności przepięcia z §5 pkt 3 (`git grep 'switch-origin\|set-url origin'` -- brak); hosty
  przepięto bez niej, a `previous-revision` wskazuje dziś commit zfsbackup (niżej).
- §6 pkt 5 mówi o 2 kontach `zfsbackup` na produkcji; zmierzone: klon konta jest na czterech hostach
  produkcyjnych (tabela).
- Przepięcie zostawiło w `.git` starą historię repo dev (MB, `du -sm .git`; refs = `refs/heads` + `refs/remotes`
  checkoutu roota):

  | host | root `.git` | konto `.git` | refs roota |
  |---|---|---|---|
  | pve1 (28.9) | 404 | 401 | 49 |
  | pve2 (28.8) | 407 | 392 | 41 |
  | pve0 (11.10) | 407 | 271 | 31 |
  | pve1 (11.11) | 404 | 271 | 8 |
  | pve9 | 99 | 78 | 31 |
  | pve10 | 438 | 419 | 145 |
  | pve11 | 320 | 163 | 86 |

  Na pve2: 354 MB luźnych obiektów, 48 MB w paczkach, 926 wpisów reflog. `previous-revision` = `630841d2`
  (osiągalny z `origin/main`), brak `stash`, jeden worktree.
- Checkout roota trzyma pliki ignorowane, które są konfiguracją hosta (pve2: `jobs.pve2.conf` i kopie,
  `cron.txt`); klon konta: `jobs.test.conf`. Dlatego **nie** proponuję ponownego klonowania katalogu.

### 9.2 Propozycja: sprzątanie w miejscu

Na każdej instalacji, root i konto w jednym oknie czasowym:

1. zapis: `git rev-parse HEAD`, `git status --porcelain --ignored`, `du -sm .git`;
2. plik `update-hold` w katalogu stanu roota (`update-control.sh:44`). Konto nie ma holdu (cron
   `git pull --ff-only`, `deploy.sh:7868`), dlatego pkt 3-5 poza minutą :15 (np. między :20 a :10);
3. usunięcie wszystkich refów poza `refs/heads/main` i `refs/remotes/origin/main`;
   `git fetch --prune --prune-tags origin` (tagi tylko z zfsbackup);
4. `git reflog expire --expire=now --all` i `git gc --prune=now`;
5. kontrola: `HEAD` bez zmian, `git status --porcelain --ignored` identyczny z pkt 1, `git fsck` bez błędów,
   `previous-revision` osiągalny, `du -sm .git`;
6. zdjęcie holdu; po najbliższym :15 odczyt `git-pull.log` i `--version`.

Bez zmiany kodu i bez zmiany plików roboczych. Kolejność jak w §6: lab (pve9, pve10, pve11; pve9b gdy wróci),
potem produkcja host po hoście za zgodą właściciela.

### 9.3 Pytania do recenzenta

1. Czy sprzątanie w miejscu (§9.2) zamiast ponownego klonu jest właściwe przy plikach konfiguracji w checkoucie?
2. Czy czynność ma być w kodzie (`update-control.sh`), czy wystarczy jednorazowy krok z runbooka?
3. Czy po §9.2 coś jeszcze blokuje §6 pkt 6 (repo dev prywatne)? Otwarte z §7: limit CI dla repo prywatnych.
   Dokumentacja GitHuba (2026-10-30): w cenie planu Free jest 12 USD miesięcznie na obliczenia, Linux po
   0,006 USD/min (~2000 min, jak w §7); zużycie naszej baterii niezmierzone.
