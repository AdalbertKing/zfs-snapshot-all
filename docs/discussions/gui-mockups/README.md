# Makiety GUI

Materiał do `docs/discussions/OWNER-GUI-DECISION-2026-09-04.md`. Nic tu nie jest
kodem produktu i nic nie jest instalowane; to obrazki do dyskusji.

## `tui/` — aktualny nośnik

Rozstrzygnięcie właściciela z 2026-09-05: interfejs ma być **pełnoekranowym
trybem tekstowym w sesji SSH**, bo admin łączy się z domu przez VPN i PuTTY i ma
tylko tekst. Te dwa pliki są szkicami w docelowym medium, przy 80 kolumnach,
czyli w przypadku projektowym, nie awaryjnym.

- `ekran-glowny-80.txt` — układ z 2026-09-06 według specyfikacji właściciela:
  lista relacji ze stanem, a pod nią panel szczegółów dla wiersza z focusem.
  Mieści się w 20 z 24 wierszy.
- `wariant-zakladki-80.txt` — wcześniejszy wariant z zakładkami i sekcją
  „Wymaga uwagi”, bez panelu. Zachowany, bo pasek F-klawiszy i sekcja alarmów
  z niego zostają.

Markery `!`, `!!` i `?` stoją w tych plikach za kolor, którego czysty tekst nie
niesie. W terminalu werdykt niosą tło i barwa znaku, a te markery są wariantem
dla terminala bez koloru — jedno z wymagań kontraktu z §2 dokumentu decyzji.

## `web-odrzucony/` — wariant odrzucony, zachowany dla architektury informacji

Sześć plansz przeglądarkowych z 2026-09-04, zrobionych zanim właściciel
rozstrzygnął nośnik. **Wariant przeglądarkowy jest odrzucony** i nie należy ich
czytać jako propozycji. Zostają, bo przeżyła je warstwa, która nie zależy od
medium:

- **które okna w ogóle istnieją** i co każde z nich odpowiada: co mam, co teraz
  leci, czy snapshoty są świeże, gdzie są nośniki;
- **teza, że GUI nie spłaszcza żadnego stanu, który CLI już rozróżnia.** Stąd
  osobny wygląd dla „brak zapisu w historii”, „cron idzie przez inny endpoint”
  i „nie ten dysk”, oraz czwarty kolor dla `UNKNOWN`, który nie jest ani OK,
  ani awarią;
- **cztery stany nośnika zamiast flagi** obecny/nieobecny, bo boolean schowałby
  ten jedyny groźny.

Pliki `.dc.html` to plansze kanwy projektowej, każda jest samodzielnym
dokumentem HTML i otwiera się w przeglądarce. `canvas.json` opisuje ich
rozmieszczenie. Dane w nich są zmyślone; prawdziwe są tylko nazwy hostów z
estaty i kształty pól.
