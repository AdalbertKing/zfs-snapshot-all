# Odzysk z repliki (nośnik wymienny)

Wersja angielska: [RESTORE-FROM-REPLICA.md](../en/RESTORE-FROM-REPLICA.md).

Wszystkie komendy jako **root na kolektorze**. Przykłady: pula nośnika `repl`.

Replika to lustro drzewa kopii: `repl/replica/<ścieżka kopii na kolektorze>`.
Żadna relacja na nią nie wskazuje — dysk leży w szufladzie i nie ma go w niczyich
rekordach. Dlatego adresuje się ją przez `--from-copy`, który nie potrzebuje
rekordu relacji.

## 1. Popatrz, zanim dotkniesz

```
zfs-media-gate.sh status repl weekly
```

`repl` to nazwa puli, `weekly` etykieta zadania — oba z sekcji `[replica:weekly]`
w configu. Odpowie, czy nośnik jest i czy wolno go wypiąć.

## 2. Podłącz

```
zfs-media-gate.sh attach repl weekly
```

Kody wyjścia znaczą trzy różne rzeczy: `0` nośnik jest, `1` **nie ma go i to nie
jest błąd**, `2` coś jest nie tak i potrzebny człowiek.

## 3. Zobacz, co na nim leży

```
zfs list -H -o name -r repl/replica | head -30
```

## 3a. Klucz nośnika zaszyfrowanego

`zfs-media-gate.sh attach` importuje pulę, ale **nie ładuje klucza**. `restore --from-copy`
robi to sam przed czymkolwiek: najpierw z pliku klucza nośnika na tym hoście (ten, który
zapisał `prepare-media`), potem z `--key-file=ŚCIEŻKA`, a gdy nie ma żadnego -- pyta o klucz
(wpisywany bez wyświetlania) albo o ścieżkę pliku. Klucz załadowany przez odzysk jest na końcu
zdejmowany.

## 4a. Odzysk NA DATASET KOPII — ten dla dużych danych

```
zfs-backup.sh restore \
    --from-copy repl/replica/hdd/backups/<host>/<ścieżka> \
    --onto      hdd/backups/<host>/<ścieżka> \
    --overwrite --config=/etc/zfs-snapshot-all/jobs.<host>.<konto>.conf
```

Cel **musi istnieć**. Schodzi delta albo samo cofnięcie — komunikat
`SAM ROLLBACK, bez transferu` znaczy: kopia miała już najnowszy punkt repliki, więc
zeszły tylko snapshoty nowsze, **zero bajtów na łączu**.

To jest powód, dla którego ten tryb istnieje. Lądowanie w wolne miejsce (4b) przy
10 TB potrzebuje drugie tyle miejsca i przenosi każdy bajt, podczas gdy dataset
kopii już stoi i dzieli historię z repliką.

**Bez `--yes`** pokazuje zbiór strat i pyta. Odpowiedz `n`, żeby tylko zobaczyć.

## 4b. Odzysk OBOK, gdy chcesz najpierw obejrzeć

```
zfs-backup.sh restore \
    --from-copy repl/replica/hdd/backups/<host>/<ścieżka> \
    --onto      hdd/podglad
```

Cel **musi być wolny**; ta forma nigdy nie nadpisuje. Dzieci jadą razem, każde na
swojej pozycji względnej.

Domyślnie ląduje **sam punkt** (jeden snapshot). `--with-history` przenosi wszystkie
snapshoty kopii do tego punktu (najstarszy w całości, potem przyrost) -- odtworzona kopia
kolektora ma wtedy historię i retencja nie zaczyna się od zera.

## 5. Odłącz

```
zfs-media-gate.sh detach repl weekly
```

Eksportuje **tylko jeśli sam importował** — pula podniesiona ręcznie nie zostanie
zabrana spod operatora.

## Co warto wiedzieć

**Config trzeba nazwać**, gdy host ma więcej niż jeden. Każdy należy do innego
konta i niesie inne relacje; wybór za operatora mógłby wycelować odzysk według
cudzych rekordów.

**Kilka datasetów naraz** przecinkiem, pary pozycyjne:
`--from-copy a,b --onto x,y`. Listy muszą mieć równą długość.

**Pauza dzieje się sama.** Źródło relacji nie ma, ale **cel ma** — kopia
kolektora jest zapisywana przez pull. Bieg rozpoznaje relację właściciela celu i
stawia jej harmonogram na czas odzysku (`paused 'src9'` … `resumed 'src9'`).
Niczego nie trzeba zatrzymywać ręcznie.

**Odtworzone datasety nie są montowane** — `recv -u`, celowo. Żeby zajrzeć:
`zfs set mountpoint=… && zfs mount`.

## Gdy dysk zostanie wyrwany W TRAKCIE biegu

`prepare-media` zakłada pulę nośnika z `failmode=continue`. Poniżej zachowanie ZFS
obserwowane w testach, przy utracie dysku w trakcie zapisu (`wait` to domyślne
ustawienie ZFS, dla puli założonej inaczej niż przez `prepare-media`):

| | zapis **już w locie** | **nowy** zapis po utracie dysku |
|---|---|---|
| `continue` (pula z `prepare-media`) | stoi w `D`, przeżywa `kill -9` | natychmiast `Input/output error` |
| `wait` (domyślne ZFS-a) | stoi w `D`, przeżywa `kill -9` | też stoi w `D` |

**Żadne z nich nie zabija hosta.** W testach `zpool status` odpowiadał, a
pozostałe pule były `ONLINE`. Hosta zabija `panic` — wartość, której tu nie
używamy.

**Odblokowanie, i to jest właściwa dźwignia:**

```
zpool clear <pula>
```

Samo podpięcie dysku z powrotem **nie wystarcza** — pula zostaje `SUSPENDED`, a
proces dalej stoi. Dopiero `zpool clear` ją zwalnia i wtedy zaległy sygnał
wreszcie dochodzi. Działa tak samo przy obu ustawieniach `failmode`.

**`failmode` nośnika to `continue`, ustawiane przez `prepare-media`.** Zmiana na
`wait` kupuje niewiele — procesu złapanego w połowie zapisu i tak nie ratuje, a
hosta żadne z ustawień nie zagraża. Osłoną jest to, co brama już robi: pula jest
zaimportowana **wyłącznie w oknie biegu**, a `status` mówi, kiedy wolno wypiąć.
Ekspozycja istnieje tylko w trakcie biegu, nie między nimi.
