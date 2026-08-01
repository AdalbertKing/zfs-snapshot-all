# Migracja zarządzanego bloku cron z roota na konto dedykowane

Stan: **dowód inżynierski, nie instrukcja obsługi** (REV-20260801-020 F1).
Spisany 2026-08-01 na podstawie suchego przebiegu na metropolis pve1;
rozdziały 2 i 3 zapisują to, co preflight **zmierzył** na żywym hoście.

> **Operacyjną odpowiedzią jest jedna komenda, nie ten dokument.**
>
> ```
> zfs-backup.sh migrate-to-account <konto> --preflight    # tylko odczyt
> zfs-backup.sh migrate-to-account <konto>                # jedna transakcja
> ```
>
> Robi ona wewnętrznie wszystko, co niżej rozpisane jest ręcznie: znajduje
> właściciela i żywy blok, wykrywa config z linii `# Source:`, sprawdza checkout
> konta, delegację ZFS na **wszystkich** datasetach z configu, grant quiesce
> (o ile blok używa `-q`), pokazuje jeden łączny podgląd i wykonuje jedno
> przełączenie z rollbackiem obu crontabów.
>
> Ten dokument zostaje, bo tłumaczy **dlaczego** — i bo pokazuje, co dokładnie
> zmierzono na produkcyjnym hoście. Administrator nie powinien go potrzebować.
>
> Zastrzeżenie: `migrate-to-account` **nie działał jeszcze na prawdziwej parze
> crontabów**. Do czasu przebiegu na żywo obowiązuje ta sama wstrzymana decyzja
> co dotąd.

## 1. Czym to jest i dlaczego to nie jest edycja crontaba

Host, na którym `gen-cron.sh --install` chodził jako root, ma w crontabie roota
blok `# BEGIN zfs-backup-managed`. Przeniesienie tej pracy na konto delegowane
wygląda na zmianę dwóch linii: usunąć blok u roota, zainstalować u konta.

Nie jest. Blok zawiera ścieżki, a konto to inny podmiot — z innym widokiem
systemu plików, innymi prawami ZFS i innymi prawami sudo. Każde z nich to
osobna zdolność, która musi istnieć **zanim** blok zmieni właściciela, i żadnej
z nich nie widać ani w configu, ani w crontabie. Na pierwszym prawdziwym
hoście brakowało **pięciu**.

Trybem awarii nie jest utrata danych. Zarówno delegacja ZFS, jak i ścieżka
quiesce są fail-closed, więc brakująca zdolność daje głośny błąd i zero
snapshotów. Trybem awarii jest host, który alarmuje co tick i po cichu
przestaje robić backupy, dopóki ktoś nie przeczyta poczty.

## 2. Preflight: wyrenderuj ten sam config trzy razy

Zawsze najpierw, i nic przy tym nie zmieniaj.

| | co | jak |
|---|---|---|
| **A** | blok, który żyje w tej chwili | `crontab -l \| sed -n '/^# BEGIN zfs-backup-managed/,/^# END zfs-backup-managed/p'` |
| **B** | ten sam config wyrenderowany dzisiejszym `gen-cron.sh`, jako root | `gen-cron.sh -c <config>` (bez `--install`) |
| **C** | ten sam config wyrenderowany jako konto docelowe | `gen-cron.sh` **konta**, przez `runuser`, ze środowiskiem konta |

Dla **C** skopiuj config w miejsce czytelne dla konta; prawdziwego jeszcze nie
przenoś.

### Bramka 1 — A musi być równe B, bajt w bajt

To dowodzi, że config jest źródłem prawdy: nadal opisuje to, co faktycznie
chodzi, a dzisiejsze narzędzie odtwarza go bez dryfu. Jeśli A i B się różnią,
migracja przepisałaby produkcję z nieaktualnego źródła. Stop, najpierw
uzgodnić config.

Host, na którym plik configu **nie istnieje**, nie przechodzi tej bramki z
definicji — B nie da się wyprodukować. To dzisiejszy stan metropolis pve2,
patrz `docs/PROJECT_STATUS.md`.

### Bramka 2 — B i C mogą różnić się wyłącznie ścieżkami

Znormalizuj B, podstawiając ścieżki celu w miejsce rootowych:

```
/root/scripts/zfs-snapshot-all/ -> <home>/zfs-snapshot-all/
/root/scripts/cron.log          -> <home>/cron.log
/root/scripts/notify-fail.sh    -> <home>/notify-fail.sh
/root/scripts/notify-warn.sh    -> <home>/notify-warn.sh
```

Po tym jedyne dopuszczalne różnice to linia `# Source:` oraz linie, których
konto nie może posiadać (patrz 3.4). **Każdy harmonogram, lista datasetów,
wzorzec, flaga retencji, flaga quiesce i próg monitora muszą być identyczne.**
Cokolwiek innego znaczy, że zmiana tożsamości jest jednocześnie zmianą
zachowania — a tych dwóch nie wolno robić w jednym kroku.

## 3. Pięć brakujących zdolności

Zmierzone na metropolis pve1, 2026-08-01, na żywym bloku 15 linii.

### 3.1 Config leży tam, gdzie konto nie sięga

`/root` na hoście Proxmox ma tryb `0700`. To, że `/root/scripts` jest czytelny
dla wszystkich, nic nie daje: konto nie przejdzie przez `/root`.

Na pve1 config był dodatkowo **nietrackowany i ignorowany przez gita, siedząc
wewnątrz checkoutu** (`/root/scripts/zfs-snapshot-all/jobs.pve1.v4.conf`) i
miał tryb `0600` po błędzie przepisywania `mktemp`+`mv`, naprawionym w
`2b29db1`. Przeszukanie całego systemu plików nie znalazło żadnej kopii. Jedno
`git clean -xdf` w tym checkoucie zniszczyłoby jedyny opis 15 produkcyjnych
zadań — dokładnie tak pve2 stracił swój.

**Naprawa:** przenieść do `/etc/zfs-snapshot-all/`, tryb `0644`, właściciel
`root:root`. To poza checkoutem i czytelne dla konta.

### 3.2 Delegacja ZFS jest per dataset nadrzędny i nie bierze się znikąd

Zadania pve1 wymieniają pięć datasetów w dwóch korzeniach. `zfs allow`
pokazał, że konto ma pełne uprawnienia na `rpool/data` i `rpool/ROOT/pve-1` —
oraz **nic** na `hdd/vm-disks`, gdzie leżą cztery z pięciu.

Sprawdzone, nie założone, z kontrolą pozytywną:

```
zfs snapshot hdd/vm-disks/vm-100-disk-0@permcheck-...   -> permission denied
zfs snapshot rpool/data/vm-106-disk-0@permcheck-...     -> ok, konto samo go
                                                           potem skasowało
```

Wynik negatywny znaczy cokolwiek tylko dlatego, że ten sam ruch udał się na
datasecie delegowanym. Bez tej kontroli „permission denied" mogłoby równie
dobrze oznaczać zepsute konto.

**Naprawa:** delegować każdy nadrzędny dataset wymieniony w configu, używając
`deploy.sh --backup-user`, żeby zestaw czasowników został w jednym miejscu
(`contract:delegation-verbs`), a nie był klepany ręcznie.

### 3.3 Quiesce wymaga jawnego grantu, per gość

Cztery linie pve1 niosą `-q auto`. Jako root to bezpośrednio `qm`/`pct`; jako
konto wymaga `/usr/local/sbin/zfs-quiesce-helper` osiągalnego przez regułę
sudo ograniczoną do konkretnych identyfikatorów gości.

Helper był zainstalowany. Reguły sudo nie było, a `/etc/zfs-quiesce-allow/`
był pusty:

```
runuser --user zfsbackup -- sudo -n /usr/local/sbin/zfs-quiesce-helper status 106
sudo: a password is required
```

`lib-zfs-snap.sh` sonduje to **zanim cokolwiek zamrozi** i wychodzi z kodem 3 z
komunikatem. Konsekwencją są więc cztery padające linie, a nie cztery backupy
crash-consistent udające aplikacyjnie spójne. Ta różnica jest całym powodem,
dla którego sonda idzie pierwsza.

**Naprawa:** `deploy.sh --join <pakiet> --allow-quiesce` na hoście źródłowym,
z dokładnie tymi identyfikatorami gości, do których należą datasety z configu.

### 3.4 W bloku są linie ogólnohostowe, których konto nie może przejąć

Blok pve1 kończy się:

```
0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log
```

Digest jest świadomie **jeden na host** — `deploy.sh --backup-user` nie
instaluje `alert-digest.sh` kontom, a `zfs-backup.sh` renderuje blok konta z
`DIGEST_SCRIPT=none`. Przeniesienie bloku kasuje więc digest i nic go nie
zastępuje.

Brak dziennego podsumowania nikogo nie alarmuje. To jedyna luka z tej listy,
która jest **cicha**.

**Naprawa — poprawiona po REV-20260801-020 F2.** Pierwsza wersja tego dokumentu
kazała dopisać digest do crontaba roota jako zwykłą, niezarządzaną linię.
Recenzent słusznie to odrzucił: dzieli jedno wdrożenie między to, co należy do
narzędzia, i to, co człowiek ma pamiętać w nieskończoność. Druga migracja
zduplikowałaby taką linię, `remove-client` nie wie, czy jest jego, a żaden
podgląd nie pokaże całej zmiany.

Linie ogólnohostowe dostają **własny blok narzędzia** w crontabie roota:

```
# BEGIN zfs-backup-host (host-level jobs kept by zfs-backup.sh -- do not hand-edit)
0 7 * * * /root/scripts/alert-digest.sh 2>>/root/scripts/cron.log
# END zfs-backup-host
```

Przepisywany w całości i idempotentnie, kasowany gdy zbiór jest pusty (żeby
migracja odwrotna mogła oddać te linie z powrotem), obecny w podglądzie i w
rollbacku. Zbiór nie jest listą wpisaną na sztywno — to każda linia z bloku
roota, której render konta nie odtwarza.

### 3.5 Logrotate konta nie obejmował logu, do którego pisze cron konta

Sekcja konta w `deploy.sh` rotowała `git-pull.log` i
`zfs-snapshot-stats.log` — poprawnie, dopóki konto robiło wyłącznie git-pull i
pracę po stronie odbiorczej; błędnie od chwili, gdy zarządzany blok można
zainstalować **dla** konta. Każda generowana linia przekierowuje do
`$HOME/cron.log`, a ten plik nie był rotowany. Rootowy odpowiednik na pve1 to
~250 KB po jednym dniu i 2,3 MB do miesięcznej rotacji.

**Naprawione w kodzie** (ten commit): sekcja wymienia teraz `cron.log`, a
marker podbity do v2, żeby istniejące hosty faktycznie to dostały. Przypięte
przez `test/zfsbackup/run.sh` sekcja 20.

## 4. Kolejność wykonania

Zasada porządkowania: **uczyń konto w pełni zdolnym, póki zadania nadal należą
do roota.** Każdą zdolność potwierdza się wtedy bez presji czasu, a przełączenie
tożsamości staje się najmniejszym i najłatwiej odwracalnym krokiem sekwencji.

### Krok 0 — Zrzut

```
crontab -l                    > root.crontab
crontab -u <konto> -l         > konto.crontab     # "no crontab for" jest OK
cp <config>                     config.bak
zfs allow <każdy pool>        > allow.before
ls -la /etc/sudoers.d/ /etc/zfs-quiesce-allow/
zfs list -t snapshot -o name,creation -r <poole> > snapshots.before
```

**Oba** crontaby, nie tylko roota. Przy koncie dedykowanym zarządzany blok
ląduje w crontabie *tego konta*, a bez jego zrzutu wspierana ścieżka teardownu
jest niedostępna, gdyby coś później poszło nie tak.

### Krok 1 — Preflight (rozdział 2). Tylko odczyt. Obie bramki muszą przejść.

### Krok 2 — Wyprowadzić config spod `/root`

```
install -d -m 0755 /etc/zfs-snapshot-all
mv <config> /etc/zfs-snapshot-all/<nazwa>.conf
chmod 0644  /etc/zfs-snapshot-all/<nazwa>.conf
gen-cron.sh -c /etc/zfs-snapshot-all/<nazwa>.conf --install
```

**Bramka:** `diff` crontaba względem `root.crontab` — jedyną zmienioną linią
może być `# Source:`. Root nadal jest właścicielem wszystkiego; to izoluje
zmianę ścieżki od zmiany tożsamości i wyprowadza config z checkoutu.

### Krok 3 — Delegacja ZFS na każdy dataset wymieniony w configu

**Bramka:** jako konto utworzyć i skasować jednorazowy snapshot na każdym
nadrzędnym datasecie. Oba czasowniki, każdy dataset, potem sprzątnąć. Dataset,
który tu polegnie, polegnie później po cichu jako „0 snapshotów".

### Krok 4 — Grant quiesce, jeśli którakolwiek linia używa `-q`

**Bramka:** `sudo -n zfs-quiesce-helper status <id>` przechodzi dla każdego
nadanego id **i jest odrzucone dla nienadanego**. Potem jedno prawdziwe
freeze/thaw na działającym gościu, poza oknem pvesr — najpierw sprawdź
`pvesr status` i `NextSync`, i trzymaj się od niego z daleka.

### Krok 5 — Uruchomić linie konta ręcznie, póki cron należy do roota

Weź render C i wykonaj każdą linię dosłownie jako konto, w kolejności:
snapshot, prune, monitor. To krok, który wyłapuje to, czego żadna kontrola
statyczna nie złapie.

Linie prune są niszczące. Są tu bezpieczne wyłącznie dlatego, że Bramka 2
udowodniła identyczny co do bajta zakres z rootowym — i dlatego preflight nie
jest opcjonalny.

### Krok 6 — Przełączenie

Wybierz minutę z dala od zaplanowanych linii. Potem, w tej kolejności:

1. usuń zarządzany blok z crontaba roota;
2. **natychmiast** dopisz linie ogólnohostowe z 3.4 do crontaba roota;
3. zainstaluj blok jako konto.

Punkt 1 musi poprzedzać punkt 3, bo `assert_no_foreign_managed_block` odmawia
instalacji dla konta, dopóki root nosi blok — świadomie, żeby podwójne
uruchamianie tych samych zadań pod dwiema tożsamościami było decyzją, a nie
wypadkiem.

> **Historia tej bramki** (REV-20260801-018/-019, naprawione w `1d5a8c4`).
> Do tego commitu `assert_no_foreign_managed_block` rozstrzygał tożsamość
> obciążenia po **znormalizowanej ścieżce configu** z linii `# Source:`.
> Krok 2 tę ścieżkę celowo zmienia, więc w tej kolejności bramka działała
> przypadkiem — ale wystarczyło **skopiować** config zamiast przenieść, czyli
> najbardziej naturalny odruch i dokładnie to, co robi render C w preflightcie,
> żeby przepuściła drugi, równoległy blok przy żywym bloku roota.
>
> Dziś porównywana jest **tożsamość zadań**: oba bloki są sprowadzane do linii
> zadań ze zdjętym katalogiem skryptu i logiem, a każde przecięcie to odmowa z
> wypisaniem kolidujących linii. Rozłączne zadania nadal wolno — dwa kolektory
> na jednym hoście to prawdziwe wdrożenie, nie wypadek. Krok 2 pozostaje
> przeniesieniem, nie kopią, i to jest teraz zapisane w kodzie.

**Bramka:** crontab roota równy zrzutowi minus zarządzany blok plus dopisane
linie; crontab konta równy renderowi C.

### Krok 7 — Obserwacja pełnego cyklu

Poczekaj na prawdziwy tick. Sprawdź `cron.log` konta, obecność nowego
snapshotu z oczekiwanym prefiksem, monitor zwracający 0 — i nazajutrz rano, czy
digest nadal przychodzi.

## 5. Rollback

Na dowolnej bramce: odtworzyć crontab roota ze zrzutu z Kroku 0, usunąć blok z
crontaba konta, przenieść config z powrotem.

Czego rollback **nie** przywraca: żadnego snapshotu skasowanego przez prune w
czasie, gdy blok należał do konta. To jedyna nieodwracalna akcja w całej
sekwencji, zachodzi nie wcześniej niż w Kroku 5, a jej zakres został w Bramce 2
udowodniony jako identyczny z rootowym. Cała reszta to przeniesienie pliku i
odtworzenie crontaba.

## 6. Co z tego trafiło do kodu

Wszystkie pięć luk znalazłem ręcznie. To był argument za komendą — i komenda
powstała (`1d5a8c4`).

| # | postulat | stan |
|---|---|---|
| 1 | jedna komenda robiąca preflight i całą migrację | **zrobione** — `migrate-to-account`, pięć faz REV-020 F3 |
| 2 | linie ogólnohostowe jako stan narzędzia | **zrobione** — blok `# BEGIN zfs-backup-host` (3.4) |
| 3 | delegacja liczona z configu, nie z linii poleceń | **zrobione** — `config_datasets()` czyta nagłówki sekcji |
| 4 | odrzucić config nietrackowany wewnątrz checkoutu gita | **niezrobione** |
| 5 | parytet logrotate konta | **zrobione** — `9b25842` |

Świadomie niezrobione, poza tabelą: faza `prepare` **przenosi config**, ale
**nie nadaje** `zfs allow` ani grantu quiesce (REV-020 F1). Wypisuje dokładną
komendę `deploy.sh` dla każdego z nich i odmawia. Nadawanie ich stąd oznacza, że
`zfs-backup.sh` przejmuje uprzywilejowaną powierzchnię `deploy.sh` — co jest
sprzeczne z `docs/discussions/DEPLOY-UX-AGREED-POSITION.md` i jest decyzją
właściciela i recenzenta, nie moją do cichego przekroczenia.

## 7. Obserwacja dla właściciela, poza tą procedurą

pve1 uruchamia VM 102 (`neth`) z `hdd/vm-disks/vm-102-disk-0`. Jest replikowana
na pve2 przez pvesr co trzy godziny, ale **nie występuje w żadnym zadaniu
snapshotowym** — ma więc pokrycie DR i zero retencji. Goście 100, 101, 106 i 107
na tym samym hoście mają jedno i drugie. Może to być świadome; migracji nie
blokuje tak czy inaczej.
