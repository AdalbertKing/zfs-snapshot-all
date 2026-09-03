# Wynik labu — silniki bez `eval`

Odpowiedź na `docs/discussions/LAB-ENGINE-EVAL-2026-09-03.md`.

Wykonawca: wątek z dostępem do floty, 2026-09-03.
Hosty: **pve9** (192.168.28.99, silnik) → **pve10** (192.168.28.97, cel zdalny),
pula `hdd` po obu stronach, jako root.

Kod nowy: **`5d81fbf`** (main; PR #306 **już scalony** w chwili labu — runbook
opisuje go jako gałąź do przetestowania).
Kod stary: **`abfda49`** — merge bezpośrednio przed `ea6628e`, czyli dokładnie
baza, którą runbook nazywa. Porównanie jest więc „main teraz vs main sprzed
zmiany", a nie „gałąź vs main".

**Werdykt: wszystkie cztery własności (A–D) potwierdzone. Zero regresji.**
Znaleziono natomiast **cztery błędy w samym runbooku** — opisane niżej, bo bez
ich obejścia lab nie da się wykonać tak, jak napisano.

## Tabela wyników

| krok | co | predykcja | wynik |
|---|---|---|---|
| 0 | `eval` w silnikach | tylko w komentarzach | **snapsend 2, snapget 1, lib 1 — wszystkie w komentarzach**, `delsnaps`/`check-snap-age` 0 |
| 0 | `test/evalfree` | 16 passed, 0 failed | **PASS=16 FAIL=0** |
| A | zapowiedź z tty, send lokalny | `rc=0`, jedna linia, dzieci przyjechały | **rc=0**, `about to move 64.2 MiB -- mbuffer reports progress below`, przyjechały wszystkie 3 filesystemy **w tym `child one` ze spacją** + volume |
| B | `canmount` cel lokalny | każdy filesystem `noauto`, volume bez błędu | **noauto ×6** (w tym `child one`), volume `-`, **`Could not set canmount`: 0 linii** |
| B | `canmount` cel zdalny | jak wyżej | **noauto ×6, volume `-`**, zero błędów |
| B | tekst dla ssh vs stary | ten sam one-liner | **IDENTYCZNY BAJT W BAJT, 148 = 148 bajtów** |
| C | sonda `snapsend -A` | cztery liczby w cache | **`ratio=1.0001 raw_mbps=675.1055 comp_mbps=343.5319`** + `link_mbps=46.3111`; losowe dane → brak kompresji, zgodnie z predykcją |
| C | sonda `snapget -A` (ssh na źródle) | zwraca wynik | **`ratio=15.9774 raw_mbps=3.8201 comp_mbps=3.3205`**, cache zapisany |
| D | `canmount` stary vs nowy | identyczny | **IDENTYCZNY** (diff pusty) |
| D | log `-A` stary vs nowy | diff pusty | **PUSTY** |
| D | log zapowiedzi stary vs nowy | diff pusty | **PUSTY** po odjęciu linii postępu mbuffera — patrz błąd 4 |

Najmocniejszy pojedynczy dowód: **dataset o nazwie `child one` (ze spacją)
przyjechał i dostał `canmount=noauto`** — to jest dokładnie ten przypadek, w
którym `eval` i argv się rozjeżdżają, więc gdyby podział na słowa był zrobiony
źle, ten dataset by nie przeszedł.

## Cztery błędy w runbooku

### 1. `update-control.sh --hold` nie istnieje

Krok 0 każe wywołać `update-control.sh --hold "lab engine eval"`. Ten skrypt zna
tylko `--self-update`, `--rollback` i `--resume-updates`; `--hold` kończy się
komunikatem użycia. Wstrzymanie robi się zapisem pliku:

```
printf 'lab engine eval %s\n' "$(date +%F)" > /root/.zfs-snapshot-all-update-state/update-hold
```

(a zdejmuje `rm -f`; `--resume-updates` też zadziała). To samo dotyczy kroku 5.

### 2. Krok 3 dla celu LOKALNEGO jest niewykonalny z definicji

Runbook każe dowieść własności (C) „lokalnie dla `snapsend.sh`":

```
./snapsend.sh -m lab_ -A -r $P/lab-eval/src $P/lab-eval/dst-local
ls -l /var/lib/zfs-snap        # wpis powstal
```

Sonda nigdy nie pobiegnie, a katalog nie powstanie. `snapsend.sh:2405`:

```
if [ $AUTOTUNE -eq 1 ] && [ -n "$REMOTE_HOST" ] && [ $DRY_RUN -ne 1 ]; then
```

Autotune jest bramkowany **obecnością hosta zdalnego** — bo lokalna wysyłka i
tak nigdy nie kompresuje. Przebieg kończy się `rc=0` i milczy, co jest poprawne
(nie ma czego decydować), ale nie dowodzi niczego. Wykonano wobec tego stronę
`snapsend` **na cel zdalny**; tam sonda działa i zapisuje cache.

### 3. Krok 3 tworzy pusty przyrost, więc nie ma czego mierzyć

```
zfs snapshot -r $P/lab-eval/src@lab_b
./snapsend.sh -m lab_ -A ...
```

Między `@lab_a` a `@lab_b` nic nie zapisano, więc przyrost jest pusty, transfer
nie ma treści i sonda nie ma próbki. Log to jedno zdanie „All datasets processed
successfully". Trzeba **dopisać dane przed snapshotem**:

```
dd if=/dev/urandom of=/$P/lab-eval/src/blob2 bs=1M count=64 status=none
zfs snapshot -r $P/lab-eval/src@lab_b2
```

### 4. Diff z kroku 4 nie może być pusty przy tej metodzie

Runbook wycina liczby (`sed -E 's/[0-9]+(\.[0-9]+)?//g'`) i oczekuje pustego
diffa. Dwie rzeczy to psują:

- **linia postępu mbuffera** (`in @ MiB/s, out @ MiB/s, … buffer % full`) bywa
  obecna albo nie, zależnie od przebiegu — trzeba ją wyciąć (`grep -v 'buffer.*%
  full'`), inaczej diff nigdy nie będzie pusty;
- **krok 4 porównuje z logiem kroku 1**, a krok 3 dopisuje dane do źródła —
  więc stary przebieg wysyła 128 MiB tam, gdzie nowy wysłał 64 MiB. To wygląda
  jak różnica zachowania, a jest różnicą danych.

Rozstrzygnięte przez powtórzenie **obu** stron na tym samym stanie danych, jeden
przebieg po drugim: zapowiedzi identyczne (oba `128.3 MiB`), diff logu **pusty**,
`canmount` identyczny.

## Uwaga metodyczna do własnej roboty

Pierwsza próba porównania tekstu dla ssh dała „RÓŻNIĄ SIĘ" — i było to **moje**
zepsucie pomiaru, nie różnica produktu: stara wartość siedzi w linii
`local canmount_cmd="…"`, a `local` poza funkcją bash odrzuca, więc ekstrakcja
zwróciła pusty łańcuch. Po zdjęciu `local` wyszło 148 = 148 bajtów, identycznie.
Odnotowane, bo bez powtórzenia pomiaru zgłosiłbym nieistniejącą regresję.

## Czego nie próbowano

- **celu zdalnego z konta delegowanego** (`zfsbackup@pve10`) — po labach
  `--source-profile` para nie jest sparowana, a zakładanie relacji tylko po to
  było poza zakresem; użyto `root@pve10`. Ścieżka „konto bez delegowanego
  `canmount` → dokładnie jedna linia `Could not set canmount`" **pozostaje
  niesprawdzona na żywo**;
- `-U` (pominięcie `canmount`), `-R` (flat-recursive) — tylko `-r`;
- sondy przy danych ściśliwych (użyto losowych, zgodnie z runbookiem).

## Stan po labie

`hdd` na obu hostach z powrotem do samego `hdd` (wszystkie datasety labu
skasowane), cache autotune usunięty, pve9 na gałęzi `main` `5d81fbf`,
`update-hold` zdjęty, logi labu z `/tmp` skasowane.
