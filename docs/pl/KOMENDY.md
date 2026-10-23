# Komendy — pełna lista

Wersja angielska: [COMMANDS.md](../en/COMMANDS.md).

Ten dokument jest **spisem tego, co pakiet potrafi**, ułożonym tak, jak się
z niego korzysta, a nie alfabetycznie. Pełny zestaw flag każdego programu daje
jego własne `-h` — tutaj jest to, **po co** dana komenda istnieje i **kiedy**
się jej używa.

---

## 1. Siedem programów i podział pracy

| program | rola |
|---|---|
| `zfs-backup.sh` | **czasowniki operatora** — cykl życia relacji, sterowanie, odtwarzanie. To jest to, czego dotyka człowiek |
| `deploy.sh` | **maszyna**: zależności, konto delegowane, parowanie, zgody. Uruchamiane na hoście, którego dotyczy |
| `snapsend.sh` / `snapget.sh` | **silniki transferu** — push i pull. Wołane przez crona (snapsend także przez odzysk na miejsce), nie ręcznie. Relacja push w 1.0 to tryb CLI dla istniejącej floty (GUI jej nie tworzy) -- przepis w README, sekcja snapsend.sh |
| `delsnaps.sh` | **silnik retencji** — jedyny, który przycina snapshoty według retencji. Dane mogą jeszcze nadpisać `-f` w silnikach transferu i `restore --overwrite` (odtwarzanie na istniejący dataset, `zfs-restore.sh`) |
| `check-snap-age.sh` | **monitor** — czy backup nie zestarzał |
| `gen-cron.sh` | zamienia config na blok w crontabie |

Silniki są **zamrożone** (`docs/project/ENGINE-FREEZE.md`): zmieniają się tylko
na wyraźne polecenie właściciela, z wpisem w tamtym pliku.

---

## 2. Cykl życia relacji — normalna droga, w kolejności

Relacja to: **kolektor + maszyna chroniona + zestaw datasetów + harmonogram**.
Ma nazwę (trafia do linii crona jako `-L` i do configu jako `pair_label`), rekord na kolektorze i konto delegowane na maszynie
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

**Co obejmuje pauza:** pull, prune **i** monitor. Działa tylko tam, gdzie linie
zadań niosą `-L NAZWA` — a ono bierze się z `pair_label` w configu, więc config
bez `pair_label` (stary, ręczny) nie jest pauzowalny.

---

## 4. Odtwarzanie

### Podgląd — nic nie rusza

```bash
zfs-backup.sh restore --plan
zfs-backup.sh restore --plan --dataset=DATASET
```

Pokazuje, co da się odtworzyć, skąd, i **kiedy naprawdę** zrobiono każdy
snapshot — po właściwości ZFS `creation`, nigdy po nazwie. Nazwa i `creation`
mogą się rozjeżdżać o strefę czasową między hostami.

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

`DOKAD` to **etykieta parowania** (nazwa, pod którą kolektor zna sparowaną maszynę), nigdy dowolny host — czyli maszyna, z którą
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
2. **Pauza** — restore sam wstrzymuje harmonogram relacji na czas odtwarzania
   i po zakończeniu go wznawia (pauzę założoną wcześniej przez człowieka
   zostawia nietkniętą). Jeśli pauzy nie da się założyć, restore **odmawia**.
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

**`-H`/`-D`/`-W`/`-M`/`-Y`** w `delsnaps.sh` to *ile sztuk zostawić*; małe litery
`-h`/`-d`/`-w`/`-m`/`-y` ustawiają próg wieku — kasowane są snapshoty starsze niż
podana liczba godzin/dni/tygodni/miesięcy/lat. `-G` włącza drabinę GFS.

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
zfs-backup.sh test NAZWA             # próbny pull (dry-run) każdego datasetu relacji
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
| `/root/scripts/cron.log`, `/root/scripts/zfs-snapshot-stats.log` | logi zadań roota |
| `~/cron.log`, `~/zfs-snapshot-stats.log` | logi zadań konta delegowanego (`~` = jego katalog domowy) |

---

## 11. Pozostałe czasowniki `zfs-backup.sh`, według tematu

Pełne flagi: `zfs-backup.sh --help`. Czasowniki bez `--yes` tylko planują.

### Relacje

| czasownik | po co | przykład |
|---|---|---|
| `edit-relation` | zmień zainstalowaną relację na miejscu (sekcje generowane od nowa z profilu); bez parowania i bez ruchu danych | `zfs-backup.sh edit-relation NAZWA --profile=P --plan` |
| `delete-relation` | usuń relację w całości: zadania tutaj, konto na źródle (`deploy.sh --leave`, pomijane, gdy z tego hosta korzysta inna relacja) i rekord, co zwalnia nazwę; kopie na dysku zostają, chyba że `--destroy-copies`; bez `--yes` tylko plan | `zfs-backup.sh delete-relation NAZWA --yes` |
| `add-source` | dołóż jeden dataset do zainstalowanej relacji, po obu stronach | `zfs-backup.sh add-source NAZWA hdd/db --yes` |
| `remove-source` | wyjmij jeden dataset z relacji, po obu stronach; odebrane kopie zostają | `zfs-backup.sh remove-source NAZWA hdd/db --yes` |
| `export-relation` | zapisz deklaracje relacji jako dokument (z `--json`) | `zfs-backup.sh export-relation NAZWA --json` |
| `import-relation` | odtwórz relację z takiego pliku; bez `--yes` tylko wypisuje polecenia | `zfs-backup.sh import-relation plik.json --name=NOWA --yes` |
| `test NAZWA` | próbny pull (dry-run) każdego datasetu relacji | `zfs-backup.sh test NAZWA` |

### Repliki (kopie na wymiennych dyskach)

| czasownik | po co | przykład |
|---|---|---|
| `add-replica` | dodaj lub zmień replikę (upsert); bez `--install` tylko plan; `--ask` = okna GUI | `zfs-backup.sh add-replica usb1 --source=hdd/dane --dst=usbrep1/replica --install` |
| `list-replicas` | lista replik i stan nośnika: here, available, away, wrong_medium | `zfs-backup.sh list-replicas` |
| `run-replicas` | uruchom teraz wszystkie repliki; brak nośnika to ciche pominięcie | `zfs-backup.sh run-replicas --name=usb1` |
| `prepare-media` | przygotuj dysk na nośnik repliki (**kasuje go**); `--list` pokazuje wolne dyski | `zfs-backup.sh prepare-media usbrep1 /dev/sdX --yes` |

### Retencja

| czasownik | po co | przykład |
|---|---|---|
| `show-tiers` | szczeble retencji jednej relacji, z jej bloku w configu | `zfs-backup.sh show-tiers NAZWA` |
| `set-tiers` | zmień szczeble w configu jedną atomową podmianą | `zfs-backup.sh set-tiers NAZWA --tier=SZCZEBEL --keep=N --plan` |
| `audit-source-retention` | audyt: które źródła pull nie mają ograniczonej retencji; `--apply` dopisuje brakujące | `zfs-backup.sh audit-source-retention` |

### Odzysk

| czasownik | po co | przykład |
|---|---|---|
| `restore --plan` | co da się odtworzyć i skąd (tylko odczyt) | `zfs-backup.sh restore --plan` |
| `restore RELACJA` | odtwórz relację z jej kopii (patrz punkt 4) | `zfs-backup.sh restore NAZWA --yes` |
| `restore --from-copy` | odtwórz z kopii na tej puli, gdy rekordów relacji już nie ma — opis w [ODZYSK-Z-REPLIKI.md](ODZYSK-Z-REPLIKI.md) | `zfs-backup.sh restore --from-copy KOPIA --onto DATASET` |

### GUI

| czasownik | po co | przykład |
|---|---|---|
| `gui` | ekran sterowania (wymaga `python3`; F3 Relacje, F6 Replika) | `zfs-backup.sh gui` |

---

## 12. Dobrze wiedzieć zawczasu

**Po odtworzeniu z cofnięciem następny backup odmówi.** To poprawne: kopia trzyma
snapshoty, których źródło już nie ma, i są jedynym śladem po tym okresie.
Odmowa wymienia je z nazwy i podaje wyjście — `zfs rollback -r <kopia>@<punkt>`
robi jedno i drugie naraz, bez roota i bez ponownego wysyłania.
