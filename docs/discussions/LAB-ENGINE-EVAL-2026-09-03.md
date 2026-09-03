# Lab — silniki bez `eval`: sześć miejsc, trzy mechanizmy, ten sam ZFS

Status: **WYKONANY 2026-09-03** na `pve9` → `pve10` (root, pula `hdd`), nowy
kod `5d81fbf` (PR #306 scalony przed labem), stary `abfda49` — wynik w
`LAB-ENGINE-EVAL-WYNIK-2026-09-03.md` (commit `409fd4b`): cztery własności
potwierdzone, zero regresji. Spisany w sesji, która hostów nie widzi; poniżej
wersja poprawiona o **cztery błędy runbooka** nazwane przez wykonawcę
(`--hold` nie istnieje; sonda `-A` nie biegnie na cel lokalny; pusty przyrost
nie ma próbki; diff logów musi wyciąć linię postępu mbuffera i porównywać ten
sam stan danych), żeby następny przebieg nie potykał się o to samo. Zapis
E32 w `IMPLEMENTER-ERROR-LOG.md`.

Gałąź: `claude/package-translation-estimate-jisaqu` (PR #306). Punkt
odniesienia: `main` w chwili startu labu (`abfda49` w chwili pisania).
Zmiana: `snapsend.sh`, `snapget.sh`, `lib-zfs-snap.sh` — odmrożenie
właściciela („odmrożenie silników pod sześć eval"), wpis na górze listy w
`docs/project/ENGINE-FREEZE.md`.

## Co się zmieniło i co lab ma dowieść

Po stronie ZFS nic: ten sam `zfs send -nP` na sucho, ten sam `zfs set
canmount=noauto` po tej samej liście, te same trzy próbki w sondzie autotune.
Zmienia się, jak powłoka silnika je uruchamia:

1. **Zapowiedź rozmiaru** (`announce_transfer_size`, gałąź lokalna, oba
   silniki). Tekst próby na sucho szedł do `eval`; teraz jest dzielony na
   słowa jak prawdziwy send (`IFS=' ' read -r -a`) i wykonywany jako argv.
2. **`canmount=noauto` po odebranym poddrzewie** (`snapsend.sh`, `-r`/`-R`
   bez `-U`). Jeden łańcuch był tekstem dla ssh i `eval`-em lokalnie; teraz
   funkcja `canmount_noauto_subtree` (lokalnie) i
   `canmount_noauto_subtree_cmd` (ten sam tekst dla ssh).
3. **Sonda autotune** (`tune_probe_stream`, `-A`, po stronie danych). Snippet
   `eval`-ował łańcuch trzy razy; teraz woła funkcję `h()` trzy razy.

Suita `test/evalfree` dowodzi tego na stubach. Czego stuby nie pokażą, bo
wymagają prawdziwego `zfs`, tty i drugiej maszyny:

- **(A)** zapowiedź „about to move N -- mbuffer reports progress below"
  nadal się pojawia przy transferze z terminala, lokalnym (bez hosta) — to
  jedyny przypadek, w którym zmieniona gałąź w ogóle biegnie;
- **(B)** po odbiorze `-r` KAŻDY filesystem poddrzewa celu kończy z
  `canmount=noauto`, na celu lokalnym (nowy kod) i zdalnym (stary tekst,
  nowa funkcja go produkuje); volumeny pomijane bez błędu;
- **(C)** `-A` liczy próbkę i zapisuje cache tak samo jak przed zmianą, po
  stronie danych: lokalnie na hoście silnika dla `snapsend.sh` NA CEL ZDALNY,
  przez ssh na źródle dla `snapget.sh` — cztery liczby wracają, decyzja o
  kompresji się nie zmienia. Na cel lokalny sonda nie biegnie z definicji:
  oba silniki bramkują autotune `[ -n "$REMOTE_HOST" ]` (`snapsend.sh:2405`,
  `snapget.sh:2449`), bo lokalna wysyłka nigdy nie kompresuje;
- **(D)** rollback na `main` daje to samo zachowanie na tych samych
  datasetach (diff logów pusty poza znacznikami czasu i liczbami z próbki).

## Kroki

Wszystko jako root na `pve9`. Datasety wyrzucalne; nic z produkcji.

### 0. Wstrzymać autoaktualizację, stan przed

```
# Hold to PLIK, nie flaga: update-control.sh zna tylko --self-update/--rollback/
# --resume-updates (blad 1 pierwszego przebiegu).
printf 'lab engine eval %s\n' "$(date +%F)" > /root/.zfs-snapshot-all-update-state/update-hold
cd /root/scripts/zfs-snapshot-all && git rev-parse --short HEAD     # main przed labem
git fetch origin claude/package-translation-estimate-jisaqu
git checkout --detach origin/claude/package-translation-estimate-jisaqu
grep -cw eval snapsend.sh snapget.sh lib-zfs-snap.sh delsnaps.sh check-snap-age.sh   # slowo eval: tylko w komentarzach
./test/evalfree/run.sh | tail -1                                     # 16 passed, 0 failed
```

Dane labowe: poddrzewo z dwoma dziećmi, jednym volume'em i nazwą ze spacją,
bo to jest przypadek, w którym `eval` i argv się różnią:

```
P=hdd    # pula labowa
zfs create -p $P/lab-eval/src/child\ one
zfs create $P/lab-eval/src/child2
zfs create -V 16M $P/lab-eval/src/vol
dd if=/dev/urandom of=/$P/lab-eval/src/blob bs=1M count=64
zfs snapshot -r $P/lab-eval/src@lab_a
```

### 1. (A) Zapowiedź z terminala — send lokalny, gałąź `eval`-owa

Uruchomić Z TERMINALA (nie przez `ssh host cmd`, nie z crona — bez tty
zapowiedzi nie ma i to jest zamierzone):

```
script -qec "./snapsend.sh -m lab_ -r $P/lab-eval/src $P/lab-eval/dst-local" /tmp/lab-A.log; echo rc=$?
grep -n 'about to move' /tmp/lab-A.log             # DOKLADNIE jedna linia na dataset, rozmiar ~64M dla src
zfs list -r $P/lab-eval/dst-local                  # src, 'child one', child2, vol
```

Oczekiwane: `rc=0`, zapowiedź obecna, dzieci przyjechały. To jest jedyne
miejsce, gdzie nowy kod wykonuje `zfs send -nP` bez `eval`; zdalna zapowiedź
(krok 2) idzie starą, niezmienioną drogą przez ssh.

### 2. (B) `canmount=noauto` — cel lokalny (nowy kod) i zdalny (nowa funkcja, stary tekst)

```
zfs get -r -H -o name,value canmount $P/lab-eval/dst-local | grep -v '@'
# oczekiwane: KAZDY filesystem (src, 'child one', child2) = noauto; vol nie ma canmount i nie ma bledu w logu
grep -c 'Could not set canmount' /tmp/lab-A.log    # 0
```

Cel zdalny, z konta delegowanego, tak jak robi to cron kolektora (relacja
labowa albo bezpośrednio, jeśli klucz i scope są):

```
script -qec "./snapsend.sh -m lab_ -r $P/lab-eval/src zfsbackup@<pve10>:$P/lab-eval/dst-remote" /tmp/lab-B.log; echo rc=$?
ssh zfsbackup@<pve10> "zfs get -r -H -o name,value canmount $P/lab-eval/dst-remote | grep -v @"
# oczekiwane jak wyzej; jesli konto nie ma delegowanego 'canmount', log ma DOKLADNIE jedna linie
# "Could not set canmount=noauto across ..." — to jest stare zachowanie, nie regresja
```

Kontrola, że tekst dla ssh jest tym samym one-linerem co przed zmianą:

```
bash -c '. <(sed -n "/^canmount_noauto_subtree_cmd() {/,/^}/p" snapsend.sh); canmount_noauto_subtree_cmd "$1"' _ "$P/lab-eval/dst-remote"; echo
git show <main-sprzed-labu>:snapsend.sh | grep -o 'canmount_cmd="[^"]*"' | head -1
```

### 3. (C) Sonda autotune po stronie danych

Czyste cache, żeby sonda naprawdę pobiegła (katalog zwraca `tune_cache_dir`
w `lib-zfs-snap.sh`, TTL siedem dni). Przyrost musi NIEŚĆ DANE — pusty
przyrost nie ma próbki i log kończy się jednym zdaniem (błąd 3 pierwszego
przebiegu). Cel ZDALNY — na lokalny sonda nie biegnie (błąd 2):

```
rm -rf /var/lib/zfs-snap                               # katalog cache roota (tune_cache_dir); ZFS_SNAP_CACHE_DIR go nadpisuje
dd if=/dev/urandom of=/$P/lab-eval/src/blob2 bs=1M count=64 status=none
zfs snapshot -r $P/lab-eval/src@lab_b
./snapsend.sh -m lab_ -A -r $P/lab-eval/src root@<pve10>:$P/lab-eval/dst-remote 2>&1 | tee /tmp/lab-C1.log | grep -i 'tune\|sample\|compress'
ls -l /var/lib/zfs-snap                                # wpis powstal, cztery liczby w srodku (ratio, raw_mbps, comp_mbps, link_mbps)
```

Pull, sonda przez ssh na źródle (`snapget.sh` mierzy tam, gdzie są dane):

```
ssh zfsbackup@<pve10> "zfs snapshot -r $P/lab-eval/dst-remote@lab_c"
./snapget.sh -m lab_ -A -r zfsbackup@<pve10>:$P/lab-eval/dst-remote $P/lab-eval/pulled 2>&1 | tee /tmp/lab-C2.log | grep -i 'tune\|sample\|compress'
```

Oczekiwane: obie sondy zwracają wynik (brak „probe failed"/„autotune
skipped"), decyzja (kompresor albo brak) taka sama jak na `main` w kroku 4
dla tego samego blobu. Losowe dane → oczekiwany werdykt „bez kompresji".

### 4. (D) Rollback na `main` i porównanie

Dwie rzeczy psują diff „stary vs nowy" (błąd 4 pierwszego przebiegu): linia
postępu mbuffera (`in @ … MiB/s, out @ … buffer … % full`) bywa obecna albo
nie, zależnie od przebiegu — trzeba ją wyciąć; a krok 3 dopisał dane do
źródła, więc log z kroku 1 i log po rollbacku wysyłają INNE ilości. Porównuje
się dwa przebiegi na TYM SAMYM stanie danych, jeden po drugim: najpierw nowy
kod raz jeszcze, potem stary.

```
norm() { grep -v 'buffer.*% full' "$1" | sed -E 's/[0-9]+(\.[0-9]+)?//g'; }
# nowy kod, swiezy cel, ten sam stan zrodla:
zfs destroy -r $P/lab-eval/dst-local; rm -rf /var/lib/zfs-snap
script -qec "./snapsend.sh -m lab_ -r $P/lab-eval/src $P/lab-eval/dst-local" /tmp/lab-A1.log
zfs get -r -H -o name,value canmount $P/lab-eval/dst-local | grep -v '@' > /tmp/lab-cm1
ssh root@<pve10> "zfs destroy -r $P/lab-eval/dst-remote"
./snapsend.sh -m lab_ -A -r $P/lab-eval/src root@<pve10>:$P/lab-eval/dst-remote > /tmp/lab-C1b.log 2>&1
# stary kod, to samo:
git checkout --detach <main-sprzed-labu>
zfs destroy -r $P/lab-eval/dst-local; rm -rf /var/lib/zfs-snap
script -qec "./snapsend.sh -m lab_ -r $P/lab-eval/src $P/lab-eval/dst-local" /tmp/lab-A0.log
zfs get -r -H -o name,value canmount $P/lab-eval/dst-local | grep -v '@' > /tmp/lab-cm0
ssh root@<pve10> "zfs destroy -r $P/lab-eval/dst-remote"
./snapsend.sh -m lab_ -A -r $P/lab-eval/src root@<pve10>:$P/lab-eval/dst-remote > /tmp/lab-C0.log 2>&1
diff /tmp/lab-cm0 /tmp/lab-cm1
diff <(norm /tmp/lab-A0.log) <(norm /tmp/lab-A1.log)
diff <(norm /tmp/lab-C0.log) <(norm /tmp/lab-C1b.log)
```

Oczekiwane: `canmount` identyczne, oba diffy puste (liczby, czas i postęp
wycięte). Różnica w diffie = regresja, zgłosić z pełnym logiem obu stron.

### 5. Sprzątanie

```
zfs destroy -r $P/lab-eval
ssh zfsbackup@<pve10> "zfs destroy -r $P/lab-eval" 2>/dev/null || ssh root@<pve10> "zfs destroy -r $P/lab-eval"
git checkout main && git pull --ff-only          # albo zostac na galezi do scalenia
rm -f /root/.zfs-snapshot-all-update-state/update-hold   # albo: bash deploy.sh --resume-updates
```

## Co pozostaje niesprawdzone na żywo

Wykonawca użył `root@pve10`, bo po labach `--source-profile` para nie jest
sparowana. Ścieżka „konto delegowane BEZ `canmount` → dokładnie jedna linia
`Could not set canmount=noauto across …`" nie była mierzona; tak samo `-U`
i `-R`. Kod tych gałęzi się nie zmienił (tekst dla ssh jest bajt w bajt
stary), więc to nie jest luka tej zmiany, tylko granica tego labu.

## Co zapisać w wyniku

- SHA gałęzi i `main`, hosty, konto, pula;
- linia `about to move` z kroku 1 i `rc`;
- `zfs get canmount` z kroku 2 dla obu celów oraz liczba linii „Could not
  set canmount" (0, albo 1 z nazwanym brakiem grantu);
- wynik obu sond z kroku 3 (czy cache powstał, jaki werdykt);
- oba diffy z kroku 4 (puste, albo pełna treść);
- każde odstępstwo od tego runbooka, żeby następny przebieg go poprawił.
