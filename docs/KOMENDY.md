# Komendy — pełna lista

Stan na 2026-08-28. Ten dokument jest **spisem tego, co pakiet potrafi**, ułożonym
tak, jak się z niego korzysta, a nie alfabetycznie. Pełny zestaw flag każdego
programu daje jego własne `-h` — tutaj jest to, **po co** dana komenda istnieje
i **kiedy** się jej używa.

Gdzie coś jest dowiedzione na żywych maszynach, a gdzie nie, jest napisane
wprost. To nie jest ozdoba: pakiet pisze na cudze dane.

---

## 1. Pięć programów i podział pracy

| program | rola |
|---|---|
| `zfs-backup.sh` | **czasowniki operatora** — cykl życia relacji, sterowanie, odtwarzanie. To jest to, czego dotyka człowiek |
| `deploy.sh` | **maszyna**: zależności, konto delegowane, parowanie, zgody. Uruchamiane na hoście, którego dotyczy |
| `snapsend.sh` / `snapget.sh` | **silniki transferu** — push i pull. Wołane przez crona, nie ręcznie |
| `delsnaps.sh` | **silnik retencji** — jedyny, który kasuje |
| `check-snap-age.sh` | **monitor** — czy backup nie zestarzał |
| `gen-cron.sh` | zamienia config na blok w crontabie |

Silniki są **zamrożone** (`docs/project/ENGINE-FREEZE.md`): zmieniają się tylko
na wyraźne polecenie właściciela, z wpisem w tamtym pliku.

---

## 2. Cykl życia relacji — normalna droga, w kolejności

Relacja to: **kolektor + maszyna chroniona + zestaw datasetów + harmonogram**.
Ma nazwę (etykietę), rekord na kolektorze i konto delegowane na maszynie
chronionej.

```bash
# 1. jednym poleceniem, od zera do działającego harmonogramu
zfs-backup.sh --source=HOST:DATASET --target=KOPIA --name=NAZWA --install --yes
```

To złożenie robi za ciebie trzy kroki poniżej. Jest **idempotentne i wznawialne**
— po przerwaniu uruchamiasz dokładnie to samo jeszcze raz.

Kroki osobno — wołaj je bezpośrednio **tylko po to, żeby odblokować zaciętą
aktywację**:

```bash
zfs-backup.sh add-client NAZWA --host=HOST[:PORT] [--target=X] [--profile=NAZWA]
zfs-backup.sh seed NAZWA [--yes]              # pierwszy transfer, cron NIE instalowany
zfs-backup.sh set-endpoint NAZWA --host=HOST[:PORT]
zfs-backup.sh verify-endpoint NAZWA
zfs-backup.sh final-catchup NAZWA [--yes]
zfs-backup.sh activate-client NAZWA [--yes]   # dopiero to instaluje crona
```

**Parowanie ma dwie strony.** `add-client` produkuje wsad; na maszynie
chronionej trzeba go przyjąć:

```bash
# na maszynie chronionej, z konsoli:
deploy.sh --join=/root/<wsad>.tgz
```

`--join` jest **interaktywny z rozmysłu**: żeby zaakceptować zakres, trzeba
wpisać **liczbę datasetów**. Zgody, której odruch nie da.

---

## 3. Sterowanie relacją

```bash
zfs-backup.sh status [NAZWA]                  # co jest, w jakim stanie
zfs-backup.sh pause-client NAZWA [--reason=TEKST]
zfs-backup.sh resume-client NAZWA
zfs-backup.sh disable-client NAZWA [--reason=TEKST]
zfs-backup.sh enable-client NAZWA
zfs-backup.sh remove-client NAZWA
```

**Pauza a wyłączenie — to nie to samo i różnica jest ważna:**

- **`pause-client`** — pauza *logiczna*. Zadania tej relacji same się pomijają.
  Przełącznik orkiestracji, nie granica bezpieczeństwa: ręczne wywołanie silnika
  **bez `-L NAZWA`** nie jest zatrzymane.
- **`disable-client`** — **peer odrzuca** komendy tej relacji, także te bez `-L`.
  Egzekwowane po drugiej stronie.

**Co obejmuje pauza (od 2026-08-27):** pull, prune **i** monitor. Wcześniej prune
biegł mimo pauzy — i na labie skasował punkt odtworzenia w trakcie odzysku.
Warunek: crontab musi być wygenerowany po tej zmianie, bo `-L` na liniach prune
bierze się z `pair_label` w configu.

---

## 4. Odtwarzanie

### Podgląd — nic nie rusza

```bash
zfs-backup.sh restore --plan
zfs-backup.sh restore --plan --dataset=DATASET
```

Pokazuje, co da się odtworzyć, skąd, i **kiedy naprawdę** zrobiono każdy
snapshot — po właściwości ZFS `creation`, nigdy po nazwie. Nazwa i `creation`
rozjeżdżają się między hostami o strefę czasową; zmierzone na tym majątku.

### Odtworzenie na własną maszynę

```bash
zfs-backup.sh restore RELACJA --yes                      # cała relacja, najnowszy punkt
zfs-backup.sh restore RELACJA:DATASET --yes              # jeden dataset
zfs-backup.sh restore RELACJA --target ds1,ds2 --yes     # wybrane
zfs-backup.sh restore RELACJA --at="2026-08-10 12:00" --yes
```

`--at` to **czas zegarowy**, rozwiązywany per dataset po `creation`.

### Odtworzenie na **inną** maszynę

```bash
zfs-backup.sh restore SKAD DOKAD --yes                   # te same ścieżki
zfs-backup.sh restore SKAD:ds DOKAD:ds2 --yes            # inna ścieżka
```

`DOKAD` to **etykieta relacji, nigdy nazwa hosta** — czyli maszyna, z którą
kolektor jest już sparowany, ma przypięty klucz i może poprosić o zgodę. Nie da
się wskazać maszyny, której ten host nigdy nie spotkał. Cel musi być
**sparowany**, nie aktywowany.

### Przekazanie kopii nowej maszynie

```bash
zfs-backup.sh move-to-client SKAD DOKAD [--yes]
```

Gdy maszyna relacji została **wymieniona**. Kopia **nie rusza się z dysku** —
zmienia się to, z której maszyny jest backupowana, więc **nie ma ponownego
seedu**. Odmawia, dopóki dane nie są już na nowej maszynie, i **dowodzi tego po
GUID, per dataset**. Starą relację **pauzuje**, nie kasuje.

**Kolejność jest wymuszona:** sparuj → odtwórz na nią → przekaż. Odwrotnie
harmonogram celuje w pustą maszynę.

### Trzy warunki, które muszą być spełnione

1. **Zgoda** — maszyna chroniona musi ją opublikować (punkt 5).
2. **Pauza** — relacja musi mieć zatrzymany harmonogram. Restore **odmawia**,
   jeśli nie da się jej wziąć.
3. **Cel odmontowany** przy trybie `replace` — konto delegowane nie odmontuje
   pod Linuksem.

---

## 5. Zgody — na maszynie chronionej

Uruchamiane **jako root na maszynie, która ma być zapisywana**. Kolektor nie
może nadać sobie niczego sam; to jest cała wartość tego mechanizmu.

```bash
deploy.sh --allow-restore=ETYKIETA [--replace]
deploy.sh --deny-restore=ETYKIETA
deploy.sh --show-restore=ETYKIETA
```

`--replace` jest osobne i nigdy nie wynika ze zwykłej zgody: pozwala
**zniszczyć** to, co maszyna ma teraz, i położyć starszą kopię. Bez niego
kolektor może pisać tam, gdzie jest wolne miejsce.

Zgoda **nie wygasa**. Nadaje dokładnie `receive,rollback,create,canmount,mountpoint`
i przy cofnięciu zabiera **dokładnie je** — uprawnienia backupu zostają.

---

## 6. Wdrożenie maszyny

```bash
deploy.sh                              # przygotuj hosta
deploy.sh --check-only                 # audyt, nic nie zmienia
deploy.sh --backup-user=zfsbackup      # utwórz konto delegowane
deploy.sh --self-update                # aktualizacja pakietu
deploy.sh --rollback                   # cofnij aktualizację
```

Parowanie i zakres:

```bash
deploy.sh --pair ...                   # strona inicjująca (kolektor)
deploy.sh --join=WSAD                  # strona przyjmująca
deploy.sh --draft-scope=ETYKIETA       # wypisz propozycję zakresu
deploy.sh --commit-scope=ETYKIETA      # nadaj zakres
deploy.sh --leave=ETYKIETA             # rozbierz relację po stronie peera
deploy.sh --unpair                     # zakończ relację po tej stronie
```

> **Uwaga (2026-08-28):** `deploy.sh --commit-scope=` **nie działa** — woła
> funkcję zdefiniowaną 2500 linii niżej, więc bash jej w tym miejscu nie zna.
> Ścieżka `--join` woła ją później i tam działa. Zakres nadaj przez `--join`
> albo ręcznie `zfs allow`. Wada jest na `main`, nie z ostatniej rundy.

---

## 7. Silniki — wołane przez crona

Nie uruchamia się ich ręcznie w normalnej pracy. Pełne listy flag: `-h`.

```bash
snapsend.sh [opcje] DATASETY [BAZA_CELU]      # push
snapget.sh  [opcje] ZDALNE_DATASETY [BAZA]    # pull
delsnaps.sh [opcje] DATASETY WZORZEC RETENCJA # kasowanie
check-snap-age.sh [-R] [-L ETYKIETA] DATASETY WZORZEC WARN CRIT
```

Rodziny flag, które warto znać:

| flaga | znaczenie |
|---|---|
| `-m PREFIKS` | prefiks nazwy snapshotu; przy `-e` wybiera **istniejący** |
| `-r` / `-R` | rekursja: jeden atomowy strumień / osobne zadanie na dataset |
| `-L ETYKIETA` | relacja, do której należy wywołanie — **to czyta pauza** |
| `-K` / `-k` / `-O` | klucz, przypięty known_hosts, opcje ssh |
| `-b BAJTY` | limit pasma (**bajty**, nie bity) |
| `-z` / `-Z` / `-A` | kompresja / autotune |
| `-q TRYB` | quiesce gościa przed snapshotem |
| `-f` | pełny wysył: **niszczy i odtwarza cel**, wymaga roota |
| `-F` | *snapget*: rekoncyliacja przy kolizji nazw pod innym GUID |
| `-t` | cel jest **dokładną ścieżką**, nie bazą (ścieżka odtwarzania) |

**`-H`/`-D`/`-W`/`-M`/`-Y`** w `delsnaps.sh` to *ile zostawić*; małe litery
`-h`/`-d`/`-w`/`-m`/`-y` to *ile są starsze niż*. `-G` włącza drabinę GFS.

---

## 8. Harmonogram

```bash
gen-cron.sh -c CONFIG              # wypisz blok, nic nie instaluj
gen-cron.sh -c CONFIG --install    # zainstaluj/zamień zarządzany blok
gen-cron.sh --uninstall            # zdejmij blok (config zostaje)
```

Uruchamiaj **jako konto relacji**, nie jako root — `REPO_DIR` bierze się z tego,
gdzie leży skrypt, więc root wygeneruje ścieżki roota.

**Zawsze rób kopię i diff przed instalacją.** Linia godzinnego self-update
`git pull` siedzi **poza** zarządzanym blokiem i musi przetrwać.

---

## 9. Diagnostyka

```bash
zfs-backup.sh status                 # stan wszystkich relacji
zfs-backup.sh progress               # postęp trwających transferów
zfs-backup.sh test                   # sprawdzenie środowiska
zfs-backup.sh --version
deploy.sh --check-only               # audyt hosta
deploy.sh --test-mail                # czy alerty wychodzą
```

---

## 10. Gdzie co leży

| ścieżka | co |
|---|---|
| `/etc/zfs-snapshot-all/jobs.<host>[.<konto>].conf` | config zadań |
| `/etc/zfs-snapshot-all/clients/<nazwa>.conf` | rekord relacji (kolektor) |
| `/etc/zfs-snapshot-all/peers/<etykieta>.conf` | manifest parowania |
| `/etc/zfs-snapshot-all/settings.ini` | ustawienia hosta |
| `/var/lib/zfs-snapshot-all/relationships/<etykieta>/paused` | znacznik pauzy |
| `/var/lib/zfs-snapshot-all/restore-grants/<etykieta>` | zgoda na odtwarzanie |
| `/usr/local/sbin/zfs-pair-gate` | bramka wymuszonej komendy ssh |
| `~/cron.log`, `~/zfs-snapshot-stats.log` | logi zadań konta |

---

## 11. Co jest dowiedzione na żywych maszynach

| rzecz | stan |
|---|---|
| backup push/pull, retencja, monitor | produkcja, 5 hostów |
| odtworzenie na własną maszynę — `create`, `rewind`, `replace`, `--at`, `--target` | lab pve9↔pve1, 2026-08-27 |
| odtworzenie na **inną** maszynę | lab pve9→pve2, 2026-08-28 |
| `move-to-client` + ciągłość kopii bez ponownego seedu | lab, 2026-08-28: 22 snapshoty jedną linią przez podmianę maszyny |
| pauza obejmująca prune | lab, 2026-08-28 |

**Czego nie sprawdzono:** relacji push z kopią zdalną w odtwarzaniu, oraz
gościa (VM/kontenera), który po odtworzeniu faktycznie wstaje.

---

## 12. Dwie rzeczy, o których warto wiedzieć zawczasu

**Po odtworzeniu z cofnięciem następny backup odmówi.** To poprawne: kopia trzyma
snapshoty, których źródło już nie ma, i są jedynym śladem po tym okresie.
Odmowa wymienia je z nazwy i podaje wyjście — `zfs rollback -r <kopia>@<punkt>`
robi jedno i drugie naraz, bez roota i bez ponownego wysyłania.

**Pauza logiczna jest na dzisiejszej produkcji bezwładna.** 26 linii zadań na
trzech hostach i **żadna** nie niesie `-L`, bo produkcja pracuje na starych
configach v4 bez `pair_label`. Migracja produkcji na model relacji to osobny
etap.
