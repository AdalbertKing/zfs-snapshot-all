# Kampania 3 -- plan (2026-10-23, do 14:00)

Dwie poprzednie kampanie szły ŚCIEŻKAMI: „zrób X, rozmyśl się, zrób Y”. Każda znalazła nowe
wady, bo każda szła innymi ścieżkami. Trzecia nie dokłada ścieżek, tylko szuka **klas** wad:
miejsc, gdzie GUI kłamie, gubi stan, zostawia ślad albo pęka na złym wejściu. Każdy blok ma
**niezmiennik**, czyli twierdzenie, które musi być prawdziwe po każdym kroku, oraz sposób, w
jaki sprawdza go automat. Oko nie jest sprawdzeniem.

Teren: lab (pve9, pve9b, pve10, pve11). Produkcji nie ruszam.

## Narzędzia (rano, przed blokami)

1. **Migawka stanu** (`state-snap.sh` w scratchpadzie): zapisuje config, wszystkie crontaby,
   rekordy relacji i replik, nagrobki, zgody, `zfs list`, `zfs get` z wybranymi własnościami,
   `zfs allow` oraz klucze i pliki w `/etc/zfs-snapshot-all`. Robi to na kolektorze i na każdym
   źródle. `state-diff` porównuje dwie migawki.
2. **Katalog ekranów**: każde okno zrzucone razem z kolorami (`capture-pane -e`), tytuł i
   ramka. Kursor da się odczytać z koloru, więc koniec z odgadywaniem.
3. **Prowadzenie po znacznikach, nie po liczeniu strzałek.** Krok się nie liczy, dopóki zrzut
   nie potwierdzi, gdzie stoi kursor. Dziś trzy razy „znalazłem wadę”, a był to tylko źle
   policzony Down.

## Bloki

### A. Tam i z powrotem = zero śladu (idempotencja)
Niezmiennik: X, a potem cofnięcie X, daje `state-diff` = pusty, poza ustaloną listą wyjątków
(historia, logi, nagrobek).

Pary do sprawdzenia:
- nowa relacja ↔ usuń (każdy z 5 rodzajów);
- add-source ↔ remove-source;
- pauza ↔ wznów;
- eksport, usuń, import;
- zgoda ↔ cofnij zgodę;
- nowa replika ↔ usuń;
- zmiana silnika ↔ fabryczne;
- zmiana szablonu ↔ powrót;
- zmiana adresu źródła ↔ powrót.

Szukam: osieroconych linii crona, kont, praw `zfs allow`, kluczy, plików `/etc`, zbiorów na
źródle (dziś: puste zbiory po nieudanym odzysku).

### B. GUI mówi prawdę (panele a rzeczywistość)
Niezmiennik: każda wartość w panelu zgadza się z CLI albo z `zfs` w tej samej chwili.

Audyt pole po polu na F2, F3, F4, F6 i F11:
- „Ostatni bieg”, „Następny”, „Kopie aktualne/spóźnione”, „Kopia z”;
- liczby datasetów, rozmiary, szablon, konto, kierunek;
- „Zgody”, stan pauzy, klucz nośnika.

Do tego świeżość: po każdej akcji sprawdzam, czy ekran się odświeżył i czy nie pokazuje stanu
sprzed niej. Strefy czasu: UTC na hoście, a nazwy migawek mają czas lokalny źródła.

### C. Przerwane w połowie
Niezmiennik: po przerwaniu GUI albo jego plan mówi, co zostało, a ponowienie tego samego
polecenia kończy robotę. Nic nie zostaje „zmienione i niedokończone” bez nazwy.

Przerwania:
- Ctrl-C w oknie postępu;
- zamknięcie PuTTY w trakcie;
- `kill` silnika;
- zerwanie sieci do źródła (iptables DROP) w trakcie seeda, odzysku i importu;
- wyjęcie nośnika (detach dysku testowego) w trakcie repliki;
- pełna pula celu (quota) w trakcie kopii.

### D. Równoległość
Niezmiennik: dwie rzeczy naraz albo działają, albo jedna dostaje czytelną odmowę. Nigdy cicha
utrata.

Sytuacje:
- dwa GUI naraz na pve10;
- edycja relacji w trakcie jej biegu z crona;
- F7 dwa razy;
- usuwanie relacji, którą drugie okno edytuje;
- import tej samej relacji dwa razy.

### E. Złe wejście
Niezmiennik: każde pole tekstowe albo przyjmuje wartość, albo mówi dlaczego jej nie przyjmuje.
Nigdy nie wpuszcza jej dalej do czasownika.

Wartości:
- spacje, polskie znaki, `-` na początku, 200 znaków;
- `..`, `/`, cudzysłowy, `$(`, `;`, tab, pusty string;
- nazwa zajęta, nazwa dawnej relacji z nagrobkiem;
- host bez pakietu, zły klucz SSH, port nie-22;
- cron `61 * * * *` i inne nietypowe;
- ścieżka celu wewnątrz źródła.

### F. Terminal
Niezmiennik: na 80×24 każde okno da się przeczytać i obsłużyć: żadna wartość nie znika za
przycięciem, przyciski są widoczne.

Warianty:
- 80×24 i 200×60;
- `TERM=vt100`, `TERM=putty`;
- `LANG=C` (polskie znaki);
- PuTTY z domyślnymi klawiszami: Home, End, F1–F12, Delete.

Dziś: karta przycinała „zaszyfrowane”, a `[zmiana]` wypadało za ramkę.

### G. Klawisze, systematycznie
Dla każdego okna z katalogu: Esc, Enter, Tab, Spacja, F1, Home, End, PgDn, litera i Enter na
kresce.

Niezmienniki:
- Esc nie wychodzi bez pytania, gdy coś czeka;
- litera na liście nie trafia do linii poleceń bez widocznego znaku (dziś `e` + Enter wykonało
  `e` w powłoce);
- przycisk niszczący nie jest domyślny.

### H. Słowa
Katalog ekranów idzie do `text-checker`. Szukam:
- angielskiego w polskim GUI (plany czasowników);
- klawiszy w treści okna (E88);
- nazw pozycji, których już nie ma;
- „(zostanie utworzone)” przy czymś, co istnieje;
- niespójnych nazw (kopia/replika/migawka).

### I. Błędy i odmowy
Niezmiennik: każda odmowa mówi po polsku, co się stało i co zrobić, i wraca do miejsca, z
którego da się poprawić.

Wywołania odmów:
- brak SSH, zły klucz hosta, brak pakietu, brak zgody;
- pełny dysk, kolizja nazwy, brak klucza nośnika;
- obcy nośnik, źródło bez migawek.

### J. Pomoc
F1 w każdym oknie a to, co okno naprawdę robi i jakie ma klawisze.

## Kolejność i czas
- Rano: narzędzia.
- Potem A (najwięcej śladów), C, E, G.
- Potem B, D, F, H, I, J.

Każda wada idzie paczką: gałąź, test, PR, scalenie, sprawdzenie na żywo.

O 14:00: lista testów dla właściciela (krótka, z numerami) i raport.
