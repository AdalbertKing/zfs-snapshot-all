# Przykłady configu dla zaawansowanych

Wersja angielska: [CONFIG-EXAMPLES.md](../en/CONFIG-EXAMPLES.md).

`gen-cron.sh` czyta jeden config INI na host (format CONFIG v4) i generuje z niego
zarządzany blok crontaba. Profil (`add-client --profile=NAZWA`) to tylko sposób
*wygenerowania* takiego configu dla nowej relacji; po instalacji to config jest
prawdą wykonawczą, a pisanie go lub edytowanie ręcznie jest w pełni wspieranym
sposobem — wyjściem awaryjnym dla niestandardowej polityki jest dokumentacja,
nie CLI.

Ten plik zbiera przykłady dla zaawansowanych, których CLI celowo nie próbuje
objąć. Każdy plik `.conf` tutaj to prawdziwy plik w [`examples/`](../examples/)
i generuje się bez błędów; pełna referencja pól jest w nagłówku
[`gen-cron.sh`](../../gen-cron.sh).

**Sprawdź/obejrzyj dowolny config bez dotykania crontaba** — to wypisuje
zarządzany blok na stdout i kończy się kodem niezerowym przy każdym błędzie:

```bash
./gen-cron.sh -c docs/examples/independent-tiers.conf
```

Uruchom dowolny przykład poniżej z jego własną ścieżką, żeby zobaczyć dokładnie, co generuje.

---

## 1. Niezależna retencja godzinna i dobowa, bez wymuszania GFS

[`examples/independent-tiers.conf`](../examples/independent-tiers.conf)

Dwa szczeble na jednym datasecie, każdy z własną częstotliwością i własną retencją
**liczoną w sztukach** (`keep = N` → `-<LITERA_TIERU><N>`). Liczby są niezależne — 24
godzinne i 14 dobowych — to nie kaskadowa drabina dziadek–ojciec–syn. GFS jest
osobnym, dobrowolnym wyborem (`gfs = yes` w sekcji `[prune:]`, sąsiad przykładu 4,
`gfs-ladder.conf`, w fixture'ach testowych); nie płacisz za drabinę tylko po to,
żeby trzymać dwie liczby retencji.

Generuje jedną linię wysyłki i jedną linię przycinania na szczebel:

```
5 * * * *  ... snapsend.sh -m "automated_hourly_" -e "tank/vm-100-disk-0" ...
35 * * * * ... delsnaps.sh "tank/vm-100-disk-0" "automated_hourly" -H24 ...
40 0 * * * ... delsnaps.sh "tank/vm-100-disk-0" "automated_daily"  -D14 ...
```

## 2. Zamrażanie (quiesce) tylko tam, gdzie gość to zniesie

[`examples/selective-quiesce.conf`](../examples/selective-quiesce.conf)

`quiesce` jest ustawiane per dataset i, w przeciwieństwie do automatycznego
dostrajania łącza (`-A`), **nigdy nie jest zgadywane** — tego, czy gościa można
krótko zamrozić i ile kosztuje zatrzymanie zapisów, nie widać po nazwie datasetu.
Ustaw je tylko na datasetach, których goście to zniosą:

- `agent` — `fsfreeze` przez qemu-guest-agent (VM z agentem);
- `sync` — zamrożenie na poziomie kontenera (LXC);
- `auto` — niech `snapsend.sh` wybierze zależnie od typu gościa;
- brak / `no` — migawka spójna na poziomie awarii (crash-consistent), polecenie bez zmian.

Ponieważ te trzy datasety dają różne `-q`, zostają trzema osobnymi liniami wysyłki
i nie łączą się w jedną. **Nie** zamrażaj bramy sieciowej ani niczego, czego
krótki przestój odcinałby ci własną drogę do hosta.

## 3. Krótsza retencja lokalna niż w magazynie

[`examples/short-local-long-store.conf`](../examples/short-local-long-store.conf)

Pula robocza trzyma tylko krótkie lokalne okno bezpieczeństwa (48 godzinnych =
dwie doby); długa historia leży w magazynie, który trzyma `-D90`. Każda migawka
jest nadal wysyłana — agresywnie przycinane są tylko kopie *lokalne*. Pokazane
na jednym hoście dla czytelności; typowy kształt produkcyjny to te same dwie reguły
rozdzielone na dwa hosty (źródło samo przycina krótko, magazyn przycina długo).
Retencja jest per dataset, więc każda strona ma własną politykę i żadna nie
zgaduje polityki drugiej.

## 4. Ręcznie pisane harmonogramy i wzorce przycinania

[`examples/manual-prune.conf`](../examples/manual-prune.conf)

Czysty magazyn kopii — przyjmuje wysyłki i niczego nie tworzy, więc nie ma w nim
żadnej sekcji `[dataset:]`. Retencja jest zapisana bezpośrednio w samodzielnych
sekcjach `[prune:]`. Trzy wzorce warte skopiowania:

- **dwie niezależne reguły przycinania na jednym poddrzewie**, każda na własnym
  cronie i z własnym wzorcem nazwy migawki;
- **nośnik samego strażnika** — `[prune:backup/store/hot]` ustawia `prune = no`, więc
  nie emituje linii `delsnaps` (rekurencyjny rodzic już przycina to poddrzewo),
  ale nadal emituje sprawdzenie świeżości. Powtórzenie tu reguły przycinania
  ścigałoby się z rodzicem o te same migawki i dawało alarm — przegrywający
  zgłasza „could not find any snapshots to destroy";
- **`[prune-bookmarks:]`** czyszczące osierocone bookmarki wysyłki wg progu wieku,
  niezależnie od jakiegokolwiek szczebla migawek. Wybierz `age` wyraźnie dłuższy niż
  twoja najdłuższa realna przerwa w backupie, bo inaczej zbyt wcześnie przytnie
  się także wciąż żywy bookmark wstrzymanego zadania.

## 5. Bezpieczne sprawdzenie i podgląd przed instalacją

`gen-cron.sh` nigdy nie zapisuje crontaba jako skutku ubocznego czytania configu.
Dwustopniowa dyscyplina:

```bash
# 1. Wypisz na stdout i obejrzyj. Kod niezerowy = config odrzucony.
./gen-cron.sh -c jobs.$(hostname -s).conf

# 2. Porównaj (diff) proponowany zarządzany blok z zainstalowanym, DOPIERO POTEM instaluj.
#    --install podmienia tylko zarządzany blok atomowo, czyta go z powrotem
#    i odmawia, jeśli przygotowany config nie zgadza się już z tym, co zwalidował.
./gen-cron.sh -c jobs.$(hostname -s).conf --install
```

Zawsze obejrzyj diff przed `--install`, zwłaszcza na hoście z działającymi
zadaniami — literówka w configu, która zmienia harmonogram albo ścieżkę, wychodzi
tutaj, a nie o 03:00. Nieznane nazwy pól, pola obecne, ale puste, `-r`/`-R`
przemycone w `flags` i nakładanie się wzorców w tym samym zakresie to twarde błędy
w czasie generowania, więc config, który się wygenerował, ma już sprawdzony kształt.

## 6. Świadoma ręczna modyfikacja po wygenerowaniu z profilu

Profil tylko TWORZY: generuje startowy config i potem nie ma już żadnej władzy.
Od tej chwili config jest twój do edycji, a zwykłe operacje cyklu życia zachowują
twoje zmiany:

- **reaktywacja / zmiana punktu końcowego lub transportu** odświeża w miejscu tylko
  dwa pola należące do topologii (`src`, `flags` transportu); nie generuje polityki
  na nowo z profilu. Ręcznie dostrojone `keep`, dodany szczebel czy własny
  `prune_schedule` przeżywają zmianę punktu końcowego bez zmian.
- **addytywne TWORZENIE** drugiej, nienakładającej się relacji dopisuje jej własne
  sekcje i zostawia każdą istniejącą sekcję bajt w bajt, odmawiając, jeśli nowy
  zakres nakładałby się na już istniejący.
- ponowne wyprowadzenie polityki z profilu następuje tylko tam, gdzie wyraźnie o to
  poprosisz (`migrate-profile`), który pokazuje podgląd i prosi o potwierdzenie
  przed zapisem.

Zamierzony przebieg dla niestandardowej polityki jest więc taki: pozwól profilowi
(albo ręcznie napisanemu szkieletowi) jednorazowo wygenerować poprawny config, potem
edytuj config bezpośrednio i trzymaj go pod kontrolą wersji. Po każdej edycji
sprawdzaj go krokiem 5.

---

Wyczerpującą referencję pole po polu (każdy typ sekcji, każde pole, reguły
łączenia, model rekurencji, ochrona zarezerwowanego prefiksu) znajdziesz w bloku
komentarza na początku [`gen-cron.sh`](../../gen-cron.sh).
