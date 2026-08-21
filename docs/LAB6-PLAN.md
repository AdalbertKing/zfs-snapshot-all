# LAB6 — plan kampanii: łańcuch od zera, bez zacięć

Cel nie jest „przejść kampanię". Cel jest **przejść ją bez ani jednej poprawki
po drodze**. Dopóki trzeba coś naprawić w trakcie, przebieg się nie liczy jako
potwierdzenie i zaczynamy od nowa. To jest jedyne kryterium sukcesu.

Poprzednie kampanie kończyły się listą znalezisk i to było ich zadanie. Ta ma
się skończyć **niczym**.

---

## 0. Fakty, zanim cokolwiek ruszy

### 0.1 Hostów są trzy, `pve4` nie istnieje

Zmierzone 2026-08-21 (`hostname -f`, `pvecm nodes`, `ip -o addr`):

| host | adres | klaster | rola |
|---|---|---|---|
| **pve1** | 192.168.28.9 | metropolis (pve1+pve2) | **PRODUKCJA** |
| **pve2** | 192.168.28.8 | metropolis (pve1+pve2) | **PRODUKCJA** |
| **pve9** | 192.168.28.99 | brak (wolnostojący) | czysty lab |

Klaster 192.168.11.x (pve0, pve1) jest za osobnym VPN-em bez trasy — zmierzone
wcześniej, `ping`/`ssh` nie przechodzą. Nie bierze udziału.

Topologia `pve4 <--> pve1 <-- pve2` przekłada się więc jednoznacznie na:

```
        R2 (pve1 --> pve9)
      ┌───────────────────┐
      v                   │
   pve9                  pve1  <-------- pve2
      │                   ^        R3
      └───────────────────┘
        R1 (pve9 --> pve1)
```

- **R1**: kolektor **pve1**, źródło **pve9**
- **R2**: kolektor **pve9**, źródło **pve1**  ← druga strona `<-->`
- **R3**: kolektor **pve1**, źródło **pve2**

### 0.2 Produkcja jest nietykalna

pve1 i pve2 niosą produkcję na koncie `zfsbackup`, z configów
`jobs.<host>.v4.conf`. **Lab nigdy nie celuje w to konto i nigdy w te pliki.**
Konkretne konsekwencje dla planu:

- żadnego `deploy.sh --pause` na pve1/pve2 — `pause_targets` zawsze bierze roota
  **i** konto delegowane, więc zatrzymałby produkcję razem z labem;
- wszystkie datasety labu w `hdd/lab6…`, żadnych innych;
- każde wywołanie na pve1/pve2 celowane jawnie (`--local-user=…`), nigdy
  „na czuja" — po P10 brak celowania i tak kończy się odmową, co jest siatką,
  ale nie zwalnia z celowania.

### 0.3 Trzy konta, w tym jedno nigdy nietestowane

| relacja | kolektor | konto zadań | dlaczego |
|---|---|---|---|
| R1 | pve1 | `root` | ścieżka bazowa |
| R3 | pve1 | **`bkpsvc`** | **nigdy nietestowane**: ani root, ani `zfsbackup` |
| R2 | pve9 | `zfsbackup` | konto delegowane o znanej nazwie |

`bkpsvc` przechodzi gramatykę (`local_user_name_valid`: małe litery, cyfry, `_`,
`-`, nie zaczyna się cyfrą). Po tym pve1 ma **trzy** bloki zarządzane w trzech
crontabach: `root` (R1), `bkpsvc` (R3), `zfsbackup` (produkcja). To najostrzejszy
możliwy test odmowy z P10 i `cron_known_accounts` — i dlatego tak, a nie inaczej.

### 0.4 Ryzyko przewidziane z góry, żeby dało się je obalić

Przewidywanie zapisane **przed** przebiegiem. Jeśli się nie sprawdzi, tym
lepiej — ale wtedy to ja się myliłem, a nie „wyszło przy okazji".

- **P-1: przecinki w liście źródeł mogą nie działać na ścieżce zdalnej.**
  `rux_split_source` bierze dokładnie **jeden** dataset (nie dzieli po
  przecinku). Lista po przecinkach jest obsłużona w formie **lokalnej**
  (`zfs-backup.sh:3036`, `:3162`). Ścieżka zdalna idzie
  `add-client --datasets=` → `deploy.sh --peer-datasets`, którego usage
  (`deploy.sh:402`) pokazuje `"A B"` — **spacje**.
  *Przewiduję:* `--datasets="a,b"` na ścieżce zdalnej trafi jako **jedna** nazwa
  z przecinkiem, a nie dwie. **Do zmierzenia w 3.1, przed budową czegokolwiek.**
- **P-2: `<-->` może uderzyć w parowanie kluczowane adresem.**
  Rekord parowania to `peers/<adres>.conf`. Przy R1+R2 pve9 ma pve1 jako peera
  w **obu** rolach (raz jako źródło dla niego, raz jako kolektor od niego), i
  odwrotnie. Znane ograniczenie: *jeden peer nie unosi dziś dwóch niezależnych
  relacji*.
  *Przewiduję:* R2 albo odmówi, albo nadpisze rekord R1. **To jest właściwy
  powód, dla którego ta topologia jest w planie.**
- **P-3: ręczne snapshoty serwisowe na dzieciach.** Wysyłka rekurencyjna niesie
  wszystkie snapshoty datasetu i jego dzieci. Snapshot spoza naszego prefiksu
  nie jest znany retencji (`delsnaps` tnie po prefiksie), ale **jest** widziany
  przez `zfs send -I`.
  *Przewiduję:* pierwsza wysyłka po ręcznym snapshocie **przejdzie**, a problem
  — jeśli będzie — pojawi się przy retencji albo na **drugim** przeskoku, gdzie
  wspólna baza liczy się od nowa.

---

## 1. Rozbiórka narzędziem — i obserwacja, co zostało

Nie „posprzątać", tylko **zmierzyć, czego narzędzie nie rusza i czy słusznie**.

### 1.1 Zdjęcie stanu przed (na każdym z trzech hostów)

```bash
hostname -s; git -C /root/scripts/zfs-snapshot-all rev-parse --short HEAD
ls -1 /etc/zfs-snapshot-all/clients/ /etc/zfs-snapshot-all/peers/ 2>/dev/null
for u in root $(ls /var/spool/cron/crontabs 2>/dev/null); do
    crontab -u "$u" -l 2>/dev/null | grep -m1 '^# Source: '
done
zfs list -H -o name | grep -i lab
ls -1 /root/.ssh/pairing/ /home/*/.ssh/pairing/ 2>/dev/null
id zfsbackup 2>/dev/null; ls -1d /etc/zfs-snapshot-all/relationships/* 2>/dev/null
```

**Kopia crontabów do pliku przed czymkolwiek** — obowiązkowo, na każdym hoście.

### 1.2 Audyt, potem rozbiórka, potem audyt ponownie

```bash
./clean-relationships.sh                      # audyt: co widzi
./clean-relationships.sh --purge=<nazwa> --yes # jedna relacja na raz
./clean-relationships.sh                      # audyt: co zostało
```

Kolejność ma znaczenie — najpierw kolektory (pve1, pve2), na końcu pve9,
żeby rekordy po stronie źródła miały jeszcze swoje odpowiedniki.

### 1.3 Co konkretnie oglądamy

Dla **każdej** pozostałości jedno pytanie: *czy narzędzie słusznie tego nie
rusza, czy to luka w zakresie?*

| ślad | oczekiwanie | pytanie |
|---|---|---|
| datasety `hdd/lab*` | **zostają** — narzędzie nigdy nie niszczy danych | słusznie (decyzja właściciela) |
| nagrobek w `removed/` | zostaje | słusznie — to jedyne, co nazywa dane po rekordzie |
| konto delegowane + `/home/<konto>` | usuwane przez `deluser --remove-home` | czy home znika naprawdę? |
| klucze `pairing-<adres>_*` | usuwane | czy po obu stronach? |
| `server.conf` | **nie ma go na żadnym hoście** | czy to luka, skoro kod go czyta? |
| wpisy `known_hosts`/aliasy | ? | **nieznane — do zmierzenia** |
| `relationships/<label>/` | usuwane | czy pusty katalog znika? |
| blok w crontabie | usuwany przez `remove-client` | czy `clean-relationships` też umie? |

Ostatnie dwa wiersze i `server.conf` to kandydaci na rozszerzenie zakresu.
**Nie rozszerzam go w trakcie kampanii** — zapis do listy, decyzja po.

### 1.4 Ręczne dokończenie

Dopiero po audycie, jawną listą ścieżek, **nigdy `rm -rf` po wzorcu**:

```bash
zfs destroy -r hdd/lab4  hdd/lab4backups  hdd/lab4chain    # per host, co istnieje
```

`zfs destroy` bez `-r` tam, gdzie nie ma dzieci — żeby brak `-r` sam potwierdził
brak dzieci. Po każdym: `zfs list | grep lab` musi być puste.

---

## 2. Punkt zerowy — dowód, że jest czysto

Na wszystkich trzech: brak `clients/*`, brak `peers/*`, brak bloku zarządzanego
poza produkcyjnym na pve1/pve2, brak datasetów `lab*`, brak kluczy `pairing/*`.

**Crontab produkcyjny na pve1 i pve2 musi mieć md5 identyczny jak w 1.1.**
To jest kontrola, że rozbiórka nie dotknęła produkcji, i jest warunkiem
przejścia dalej.

---

## 3. Budowa źródeł

### 3.1 Najpierw zmierz P-1 (przecinki), zanim zbudujesz cokolwiek

```bash
# forma lokalna -- ma zadzialac
zfs-backup.sh --source=hdd/lab6/tree,hdd/lab6/flat --target=hdd/lab6local
# forma zdalna -- SPRAWDZ, nie zakladaj
zfs-backup.sh add-client testcommas --host=… --datasets="hdd/lab6/tree,hdd/lab6/flat"
```

Wynik przesądza, czy R1/R3 dostają listę przecinkową, czy trzeba spacji. Wpis
do LAB6-OBSERWACJE niezależnie od wyniku.

### 3.2 Datasety

Na **pve9** (źródło R1):

```bash
zfs create -p hdd/lab6/tree          # Z DZIECMI
zfs create    hdd/lab6/tree/a
zfs create    hdd/lab6/tree/b
zfs create    hdd/lab6/flat          # BEZ DZIECI
# dane, zeby wysylka miala co niesc i zeby dalo sie porownac md5
for d in tree tree/a tree/b flat; do
    dd if=/dev/urandom of=/hdd/lab6/$d/plik.bin bs=1M count=8 status=none
done
```

Na **pve1** (źródło R2): `hdd/lab6src/flat` + później `hdd/lab6chain` (lądowisko
R3) — to ono robi z tego **łańcuch dwuprzeskokowy**.

Na **pve2** (źródło R3): `hdd/lab6src/tree` z jednym dzieckiem.

---

## 4. Wdrożenia — trzy relacje, trzy różne drogi

Świadomie różne, żeby jeden przebieg pokrył trzy ścieżki kodu.

### R1 — pve1 ← pve9, konto `root`, **join automatyczny przez SSH**

```bash
[pve1] zfs-backup.sh --source=192.168.28.99:hdd/lab6/tree \
                     --target=hdd/lab6r1 --name=lab6-r1 \
                     --grant-remotely --install
```

`--grant-remotely` podpisuje zakres **dokładnie żądany** — czyli omija szkic
całego inwentarza (to była wada P5). Sprawdzamy, że nadal tak jest.

### R3 — pve1 ← pve2, konto **`bkpsvc`**, **join ręczny**

```bash
[pve1] zfs-backup.sh add-client lab6-r3 --host=192.168.28.8 \
                     --datasets=<wg wyniku 3.1> \
                     --target=hdd/lab6chain --local-user=bkpsvc
[pve2] deploy.sh --join …                 # ręcznie, z terminalem
[pve1] zfs-backup.sh seed lab6-r3
[pve1] zfs-backup.sh verify-endpoint lab6-r3
[pve1] zfs-backup.sh activate-client lab6-r3
```

Tu pada najwięcej nowego: nieznane konto, ręczny join, lista datasetów, i pve1
z **trzema** blokami zarządzanymi.

### R2 — pve9 ← pve1, konto `zfsbackup`, tryb **sync**

```bash
[pve9] zfs-backup.sh --source=192.168.28.9:hdd/lab6chain \
                     --mode=sync --local-user=zfsbackup --install
```

To zamyka `<-->` **i** robi drugi przeskok łańcucha: dane pve2 lądują na pve1,
a pve1 odsyła je na pve9. Tu spodziewam się P-2.

---

## 5. Ręczne snapshoty serwisowe — „jak w życiu"

Po **udanym** pierwszym cyklu, nie wcześniej:

```bash
[pve9] zfs snapshot hdd/lab6/tree/a@przed-aktualizacja-$(date +%Y%m%d-%H%M)
[pve9] zfs snapshot hdd/lab6/tree@serwis-recznie-$(date +%Y%m%d-%H%M)
```

Prefiks celowo **spoza** naszego (`automated_`), bo tak wygląda produkcja.

Obserwacja przez trzy pełne cykle godzinowe, na **każdym** przeskoku osobno:

1. czy wysyłka przechodzi (`ZFS-JOB END … rc=0` w `cron.log`);
2. czy ręczny snapshot **dojechał** na kolektor (`zfs list -t snapshot`);
3. czy retencja go **nie skasowała** (nie pasuje do prefiksu — nie powinna);
4. czy drugi przeskok (pve1 → pve9) nadal ma wspólną bazę;
5. czy `check-snap-age.sh` nie zaczyna kłamać, licząc obcy snapshot jako świeży.

**Punkt 5 jest najbardziej podejrzany** i najłatwiejszy do przeoczenia: monitor
mówiący „świeżo", bo ktoś ręcznie zrobił snapshota, jest gorszy niż monitor
milczący.

---

## 6. Kryterium powtórki

Przebieg **liczy się** tylko wtedy, gdy:

- żadna komenda nie wymagała poprawki w kodzie,
- żadna nie wymagała ręcznego obejścia,
- wszystkie trzy relacje `active`, dane zweryfikowane md5 na każdym przeskoku,
- produkcyjne crontaby na pve1/pve2 mają md5 z punktu 1.1,
- ręczne snapshoty przeżyły trzy cykle i dojechały.

**Jeden warunek niespełniony = cała kampania od 1.1.** Nie od miejsca awarii —
od początku. Poprawka wchodzi między przebiegami, nigdy w trakcie.

---

## 7. Czego ten plan świadomie NIE robi

- nie rozszerza zakresu `clean-relationships.sh` w trakcie (tylko notuje),
- nie dotyka konta `zfsbackup` na pve1/pve2 ani plików `*.v4.conf`,
- nie używa `deploy.sh --pause` na hoście z produkcją,
- nie naprawia P-1/P-2/P-3 zawczasu — **mają wyjść albo nie wyjść**,
  bo naprawiona hipoteza niczego nie dowodzi.
