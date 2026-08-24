# LAB-CAMPAIGN 2026-08-24 — `pve1>pve9<>pve2`, wszystko pasywnie

Kampania testerska na żywej infrastrukturze. Kolektor **pve9** ma dwie nogi,
obie **pasywne** (`-e`: adoptuj najnowszy istniejący snapshot, nie stempluj
źródła):

- **noga BACKUP**: `pve1 (192.168.28.9) → pve9` — dwa źródła, konto `root`;
- **noga SYNC**: `pve9 <> pve2 (192.168.28.8)` — jedno źródło, konto `bckp`.

Dokument spisuje **użyte komendy, wygenerowane configi i crony** oraz
obserwacje. Wersja pakietu na starcie: `main@15c672c`.

## 0. Zasady i granice

- **Produkcji nie tykamy.** pve1 i pve2 to hosty produkcyjne metropolis; lab
  dostaje wyłącznie własne drzewa (`hdd/lab1a`, `hdd/lab1b` na pve1,
  `hdd/lab2s` na pve2) i po jednej otagowanej linii crona. Każda zmiana
  crontaba udokumentowana diffem przed/po.
- **Żadnych holdów poza drzewami labowymi** — `zfs hold` na datasecie
  replikowanym przez pvesr zakleszcza replikację na stałe.
- Werdykty biegów czytamy z pola `rc=` w logu, **nie** ze statusu linii crona
  (ten jest zawsze 0).
- Linie crona uruchamiamy **verbatim**; rekonstruowana linia nie jest dowodem
  (lekcja z poprzedniej kampanii).

## 1. Przewidywania spisane PRZED biegiem

1. **Główna hipoteza:** rekursja atomowa (`-r`) + ręczny snapshot serwisowy
   zrobiony **tylko na dziecku** = niespójny zestaw w drzewie. Adopcja bierze
   „najnowszy", a `zfs send -R -I` potrzebuje tej samej nazwy w całym
   poddrzewie → spodziewam się odmowy albo pełnego re-pulla.
2. Noga SYNC odtwarza ścieżki źródła 1:1 (bez własnej przestrzeni) → ryzyko
   kolizji ze strażnikiem pokrycia.
3. Monitor na nodze SYNC: rodzina vs autorstwo, wiek liczony przez dwa
   przeskoki.
4. **Stampede**: wszystkie relacje z tego samego profilu wystartują w tej
   samej minucie — znane, jeszcze nienaprawione; powinno być widać w logu.

## 2. Rekonesans (stan zastany)

### pve1 (192.168.28.9) — PRODUKCJA

```
hostname                          pve1
zfs list -d 1 hdd                 hdd 5.40T used / 5.38T avail
                                  hdd/backups, hdd/vm-disks (PRODUKCJA),
                                  hdd/lab9chain, hdd/lab9r1 (rezydua starszych labów)
crontab -l | wc -l                19
crontab -l | grep -cE 'snapsend|snapget|delsnaps|check-snap-age'   9
crontab -u zfsbackup -l | wc -l   24
pvesr status                      101-0, 102-0, 106-0 → local/pve2, wszystkie OK
```

pvesr **aktywnie replikuje pve1 → pve2**; `hdd/vm-disks` nie dotykamy w ogóle.

### pve2 (192.168.28.8) — PRODUKCJA

Po poprzedniej kampanii: 10 linii crontaba roota, 20 linii crontaba
`zfsbackup`, pula bez śladów labowych.

## 3. Przygotowanie świata zewnętrznego

### 3.1 Drzewa labowe

Na **pve1**:

```bash
zfs create -p hdd/lab1a/at/a
zfs create -p hdd/lab1a/at/b
zfs create -p hdd/lab1b/at/a
zfs create -p hdd/lab1b/at/b
zfs create -p hdd/lab1b/at/skip
# 512 KiB losowych danych w każdym datasecie
zfs snapshot -r hdd/lab1a/at@bazowy-000
zfs snapshot -r hdd/lab1b/at@bazowy-000
```

Na **pve2**:

```bash
zfs create -p hdd/lab2s/at/a
zfs create -p hdd/lab2s/at/b
zfs snapshot -r hdd/lab2s/at@bazowy-000
```

### 3.2 Generatory „cudzych" snapshotów

`/root/lab-gen-pve1.sh` — rotacja masek co tick (`nocny_`, `arch_`, **bez
prefiksu**) plus rodzina `tmpjob_` przeznaczona do wykluczenia:

```bash
ts=$(date +%Y%m%d-%H%M%S)
case $(( $(date +%-M) % 3 )) in
  0) p=nocny_ ;;
  1) p=arch_ ;;
  2) p= ;;
esac
zfs snapshot -r "hdd/lab1a/at@${p}${ts}"
zfs snapshot -r "hdd/lab1b/at@${p}${ts}"
zfs snapshot -r "hdd/lab1b/at@tmpjob_${ts}"
```

`/root/lab-gen-pve2.sh` — rotacja `repl_` / bez prefiksu:

```bash
ts=$(date +%Y%m%d-%H%M%S)
case $(( $(date +%-M) % 2 )) in
  0) p=repl_ ;;
  1) p= ;;
esac
zfs snapshot -r "hdd/lab2s/at@${p}${ts}"
```

### 3.3 Wpisy w cronie (z dowodem diffem)

pve1:

```
$ diff /tmp/c1.pre /tmp/c1.post
19a20
> */5 * * * * /root/lab-gen-pve1.sh >/dev/null 2>&1 # LAB-GEN-PVE1

$ crontab -l | grep -cE 'snapsend|snapget|delsnaps|check-snap-age'
9        # produkcja nietknięta
```

pve2:

```
$ diff /tmp/c2.pre /tmp/c2.post
10a11
> */5 * * * * /root/lab-gen-pve2.sh >/dev/null 2>&1 # LAB-GEN-PVE2
```

## 4. Rejestracje trzech relacji

### 4.1 `k1a` — pve1, rekursja atomowa, join automatyczny, konto `root`

```bash
./zfs-backup.sh --source=192.168.28.9:hdd/lab1a/at --target=hdd/k1a-tgt \
    --name=k1a --local-user=root --recursive=atomic --passive \
    --grant-remotely --install --yes
```

```
K1A EXIT=0
>>> client 'k1a' is active; endpoint and installed cron both use '192.168.28.9:22'.
>>> deploy: 'k1a' is active.
```

Zaadoptowany snapshot: `20260824-092001` — **bez żadnego prefiksu**, zgodnie
z modelem pasywnym (najnowszy istniejący, obojętne jak nazwany).

### 4.2 `k1b` — pve1, rekursja płaska, oba rodzaje wykluczeń, join RĘCZNY

```bash
./zfs-backup.sh --source=192.168.28.9:hdd/lab1b/at --target=hdd/k1b-tgt \
    --name=k1b --local-user=root --recursive=flat --passive \
    --exclude-snapshots=tmpjob_ --exclude=skip --install --yes
```

Pierwsze podejście zatrzymuje się zgodnie z projektem (`EXIT=1`) i podaje
komendę operatora. Ruch operatora **na źródle** (pve1):

```bash
printf '\n[dataset:hdd/lab1b/at]\ninclude_parent = yes\ninclude_children = yes\n' \
    >> /etc/zfs-snapshot-all/peers/pve9.scope
./deploy.sh --commit-scope=pve9
# >>> commit-scope complete for 'pve9': 7 dataset(s) granted to zfsbackup-pve9
```

Wznowienie tą samą komendą: `EXIT=0`, `'k1b' is active`.

Oba wykluczenia zweryfikowane po seedzie: dziecko `skip` **nieobecne** na
targecie (`zfs list -r hdd/k1b-tgt | grep -c skip` → `0`), rodzina `tmpjob_`
nieprzeniesiona (`grep -c tmpjob_` → `0`).

### 4.3 `k2s` — pve2, tryb SYNC, konto `bckp`

```bash
./zfs-backup.sh --source=192.168.28.8:hdd/lab2s/at --mode=sync \
    --name=k2s --local-user=bckp --passive --grant-remotely --install --yes
```

```
K2S EXIT=0
>>> client 'k2s' is active; endpoint and installed cron both use '192.168.28.8:22'.
```

Sync odtworzył ścieżki **1:1** na kolektorze: `hdd/lab2s/at`, `.../at/a`,
`.../at/b` — bez własnej przestrzeni nazw. Przewidywanie nr 2 (kolizja ze
strażnikiem pokrycia) **nie zmaterializowało się**: na pve9 nie było nic pod
tą ścieżką.

Konta rozłożone per host (`root` na pve1, `bckp` na pve2) — wymóg z PR #142:
druga relacja z innym `--local-user` do **tego samego** sparowanego hosta jest
odrzucana po imieniu.

## 5. Ręczne snapshoty serwisowe — „jak admin w trakcie pracy"

### 5.1 Drzewo atomowe: snapshot tylko na dziecku

```bash
# na pve1, między tickami generatora
zfs snapshot hdd/lab1a/at/a@przed-migracja-recznie
```

Bieg linii `k1a` **verbatim z crontaba** zaraz po tym:

```
ZFS-JOB END pve9 profile__passive__passive_hourly backup (k1a-at) rc=0
# na targecie: BEZ ZMIAN, dalej tylko 20260824-092001
```

**Obserwacja O1.** Ręczny snapshot zrobiony wyłącznie na dziecku jest dla
relacji atomowej **niewidoczny**, dopóki rodzic nie dostanie nowszego
snapshotu. Bieg kończy się `rc=0` i komunikatem „All datasets processed
successfully" — czyli cisza; admin nie dowie się, że jego snapshot jeszcze
nie jest w kopii.

Po następnym ticku cyklicznym (`20260824-092334` na rodzicu) ten sam bieg:

```
lab1a/at@20260824-092334
lab1a/at/a@przed-migracja-recznie      <-- dojechał sam
lab1a/at/a@20260824-092334
lab1a/at/b@20260824-092334
```

**Przewidywanie nr 1 OBALONE pomiarem.** Nie ma odmowy ani pełnego re-pulla:
`zfs send -R -I` niesie wszystkie snapshoty pośrednie każdego datasetu, więc
ręczna robota admina dojeżdża sama przy najbliższym cyklu. To opóźnienie,
nie utrata.

### 5.2 Drzewo płaskie: snapshot tylko na dziecku

```bash
zfs snapshot hdd/lab1b/at/b@serwis-reczny-plaski
```

Bieg `k1b` verbatim → `rc=0`, snapshot **natychmiast** na targecie (w trybie
płaskim dziecko jest samodzielnym datasetem, więc nie czeka na rodzica).

## 6. ZNALEZISKO F1 — `-E` chroni adopcję, nie chroni ani transferu, ani retencji

Ten sam bieg przyniósł na target **wykluczoną rodzinę**:

```
lab1b/at/b@tmpjob_20260824-092001
lab1b/at/b@tmpjob_20260824-092334
```

mimo że zainstalowana linia niesie `-e -E tmpjob_ -X skip`.

**Mechanizm (zmierzony, nie wydedukowany):** `-E` rządzi wyłącznie **wyborem
punktu adopcji** — wyklucza rodzinę z bycia bazą/końcem. Sam transfer to
`zfs send -I` (wszystkie snapshoty pośrednie; silnik ma opcję `-i`, która
przesyła tylko różnicę, ale profil pasywny jej nie ustawia). Wszystko, co
powstało między bazą a nowym punktem, jedzie na target — łącznie z rodzinami
zadeklarowanymi jako wykluczone.

**Korekta wcześniejszego zapisu.** Poprzednia kampania zanotowała „tryb
atomowy niesie wykluczone snapshoty, targety płaski i pojedynczy: zero".
Ta konkluzja była **pusta** — tamten generator nie tworzył wykluczonej
rodziny na źródle płaskim, więc nie było czego wykluczać. Prawda jest
niezależna od trybu rekursji: **każdy** inkrement `-I` niesie pośrednie.

**Konsekwencje:**

1. transfer i miejsce na targecie zużywane przez rodziny uznane za śmieci;
2. wykluczone rodziny **konkurują o sloty drabiny retencji** z danymi, które
   operator chce trzymać (drabina pasywna jest bezprefiksowa — patrz niżej);
3. nic tego nie mówi: ani opis flagi, ani wyjście rejestracji.

### 6.1 Co robi z tym drabina

Zainstalowana linia prune (verbatim):

```
delsnaps.sh -G -R -P "__replicate_:2" -P "vzdump:2" -P "__migration__:2" \
    "hdd/k1b-tgt/192.168.28.9" "" -H24 -D7 -W4 -M12
```

Bieg verbatim: `rc=0`, **11 → 3 snapshoty**, wszystkie `tmpjob_` usunięte.
Czyli drabina je sprząta — ale dopiero po tym, jak zostały przesłane i
zapisane.

Co zostało:

```
lab1b/at@20260824-092334
lab1b/at/a@20260824-092334
lab1b/at/b@serwis-reczny-plaski     <-- ręczna robota admina zachowana
```

**Obserwacja O2 (dobra).** Drabina działa per dataset i zachowuje najnowszy
każdego z nich — dlatego ręczny snapshot serwisowy przetrwał, choć nie należy
do żadnej cyklicznej rodziny. Kolejny bieg inkrementalny po tym prune:
`rc=0` — **łańcuch nie pękł**, bazą została ręczna robota admina.

## 7. ZNALEZISKO F2 — stampede harmonogramów, zmierzony

Rozkład minut startu, oba konta, **dwa różne hosty źródłowe**:

```
$ crontab -l | grep -E 'snapget|delsnaps|check-snap-age' | cut -d' ' -f1,2 | sort | uniq -c
      2 */15 *      # monitory
      2 1 *         # backup  k1a, k1b
      2 21 *        # prune   k1a, k1b

$ crontab -u bckp -l | ... (to samo)
      1 */15 *
      1 1 *         # backup  k2s
      1 21 *        # prune   k2s
```

Wszystkie trzy relacje — mimo dwóch kont i dwóch różnych źródeł — uderzają
w **tej samej minucie `:01`**, a prune o `:21`. Profil niesie dosłowny
`send_schedule`, więc każda relacja z niego dziedziczy tę samą minutę.
Znane, zaplanowane do naprawy (rozrzut deterministyczny w gen-cron); tutaj
udokumentowane jako pomiar, nie jako niespodzianka.

## 8. Stan po pierwszej fazie

| Relacja | Tryb | Rekursja | Join | Konto | Bieg verbatim | Monitor |
|---|---|---|---|---|---|---|
| k1a | backup | atomowa `-r` | automat | root | `rc=0` | `rc=0` |
| k1b | backup | płaska `-R` | ręczny | root | `rc=0` | `rc=0` |
| k2s | **sync** | — | automat | bckp | `rc=0` | `rc=0` |

Monitory (verbatim z crontaba):

```
./check-snap-age.sh -R -L k1a "hdd/k1a-tgt/192.168.28.9" "-" 90m 150m    -> rc=0
./check-snap-age.sh -R -L k1b -x tmpjob_ "hdd/k1b-tgt/192.168.28.9" "-" 90m 150m -> rc=0
sudo -u bckp ... -R -L k2s "hdd/lab2s/at" "-" 90m 150m                   -> rc=0
```

## 9. ZNALEZISKO F3 — admin kasuje na źródle snapshot będący bazą kopii

Scenariusz w pełni realistyczny: admin sprząta miejsce na źródle i usuwa
snapshot, który akurat jest punktem odniesienia kopii.

```bash
# na pve1 -- snapshot obecny na targecie jako baza
zfs destroy -r hdd/lab1a/at@20260824-092334
```

Bieg linii `k1a` verbatim:

```
cannot receive incremental stream: most recent snapshot of
hdd/k1a-tgt/192.168.28.9/hdd/lab1a/at/a does not match incremental source
2026-08-24 07:28:52 - Transfer failed
ZFS-JOB END ... backup (k1a-at) rc=1
```

**Fail-closed — poprawnie**: nic nie zostało zniszczone, relacja odmawia i
alarmuje. Zastrzeżenie: komunikat jest surowym tekstem ZFS-a i nie mówi
operatorowi tego, co się naprawdę stało („na źródle zniknął snapshot, od
którego liczy się przyrost"). Relacja **nie naprawia się sama** — profil
pasywny nie ustawia `-F` ani `-f`, więc kolejne biegi będą padać do czasu
interwencji człowieka.

### 9.1 Kontrast: to samo w trybie PŁASKIM — samoleczące

```bash
# na pve1, źródło relacji plaskiej
zfs destroy hdd/lab1b/at/a@20260824-092601
zfs snapshot hdd/lab1b/at/a@po-skasowaniu-bazy
```

Bieg `k1b` verbatim: **`rc=0`**, dziecko dostało komplet nowych snapshotów.
W trybie płaskim każdy dataset negocjuje **własną** bazę, więc rozjazd
jednego dziecka nie dotyka pozostałych ani relacji jako całości.

**Wniosek projektowy:** tryb atomowy kupuje spójność punktu w czasie ceną
kruchości — jeden rozjechany dataset zatrzymuje całe drzewo.

## 10. ZNALEZISKO F4 — `-F` (reconcile) zamienia uczciwą awarię w cichą rozbieżność

Ta sama sytuacja co F3, tym razem z flagą naprawczą. Ta sama linia + `-F`:

```
All datasets processed successfully
ZFS-JOB END ... backup (k1a-at) rc=0
```

Stan targetu **po** tym „sukcesie":

```
at@20260824-092001, 092334, arch_20260824-092501, 20260824-092601     <- aktualny
at/b@20260824-092001, 092334, arch_20260824-092501, 20260824-092601   <- aktualny
at/a@20260824-092001, przed-migracja-recznie, 20260824-092334         <- ZOSTAŁO W TYLE
```

Źródło dziecka `a` ma w tym czasie `arch_20260824-092501`,
`20260824-092601`, `nocny_20260824-093001` — **trzech snapshotów brakuje na
kopii**, a bieg zaraportował pełny sukces.

Pomiar **powtórzony dwukrotnie**, wynik identyczny. Bez `-F` ten sam stan
daje uczciwe `rc=1` (F3).

**To jest istota znaleziska:** flaga, której zadaniem jest pogodzenie
rozjazdu, w tym przypadku niczego nie godzi, a jedynie **tłumi błąd** —
relacja zgłasza „All datasets processed successfully", podczas gdy jedno
dziecko przestało być kopiowane.

### 10.1 Monitor tego nie łapie

```
$ ./check-snap-age.sh -v -R -L k1a "hdd/k1a-tgt/192.168.28.9" "-" 90m 150m
OK dataset=.../lab1a/at     newest=20260824-092601             age=4m
OK dataset=.../lab1a/at/a   newest=20260824-092334             age=6m   <- w tyle
OK dataset=.../lab1a/at/b   newest=20260824-092601             age=4m
rc=0
```

Monitor mierzy **wiek bezwzględny** każdego datasetu wobec progów (90m/150m),
a nie **rozjazd między rodzeństwem**. Dziecko odstające o dwa snapshoty jest
dla niego zdrowe, dopóki nie przekroczy progu czasowego — czyli przez
kolejne półtorej godziny nikt się nie dowie, a jeśli w międzyczasie coś
dołoży dziecku jakikolwiek snapshot, nie dowie się nigdy.

## 11. Podsumowanie pierwszej fazy

| # | Znalezisko | Klasa | Status |
|---|---|---|---|
| F1 | `-E` chroni tylko adopcję: wykluczone rodziny jadą na target jako snapshoty pośrednie (`send -I`) i konkurują o sloty retencji | projektowe / niedopowiedzenie | zmierzone |
| F2 | Stampede: trzy relacje, dwa konta, dwa źródła — wszystkie o `:01` | znane, w kolejce | zmierzone |
| F3 | Skasowanie bazy na źródle zatrzymuje relację atomową na stałe; komunikat surowy, brak samonaprawy (tryb płaski: samoleczący) | odporność | zmierzone |
| F4 | **`-F` raportuje pełny sukces przy niezsynchronizowanym dziecku**; monitor nie widzi rozjazdu rodzeństwa | **fail-open, cisza** | zmierzone ×2 |

Obalone przewidywania: nr 1 (atomowy + ręczny snapshot dziecka **nie** powoduje
odmowy — dojeżdża przy następnym cyklu) i nr 2 (sync nie wszedł w kolizję ze
strażnikiem pokrycia).

Potwierdzone: nr 4 (stampede).

Do rozstrzygnięcia w dalszej części kampanii: nr 3 (monitor na nodze sync
przy dwóch przeskokach wieku) — wymaga upływu czasu.
