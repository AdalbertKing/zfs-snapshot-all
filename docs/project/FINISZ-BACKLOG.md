# FINISZ -- backlog paczek (od 2026-10-18, tydzień)

Tryb pracy (właściciel 2026-10-18): właściciel zgłasza uwagi w trakcie obserwacji,
implementer zapisuje je TUTAJ (numer, słowa właściciela) i łączy w paczki. Jedna paczka =
jedna gałąź = jeden PR, scalany po zielonym CI. Bez suit lokalnie (CI ~3 min). Na żywo na
pve9 tylko to, co widać w GUI. Recenzent i łatanie -- po paczkach.

Cel: każda funkcjonalność pakietu dostępna z GUI, z chudym odzyskiem.

## Paczki (kolejność)

| # | paczka | zawartość | stan |
|---|---|---|---|
| A | Cykl relacji w GUI | relacja nie-aktywna (1. kopia, czeka na źródło, zmiana adresu w toku): w oknie relacji jeden klawisz „dokończ” = następny krok (`seed` / `verify-endpoint` / `activate`), zamiast komendy do przepisania -- ZROBIONE (`d dokończ`, #609); wyłącz/włącz -- ZROBIONE (F8: `w` = Wyłącz z wyjaśnieniem i drogą powrotu; wyłączona: F8 Włącz) | zrobione |
| B | Chudy odzysk | F11 (#608); „Przeglądaj kopię” runda 1 -- ZROBIONE #611 (F7 na F11: migawka RO, `mc`, odmontowanie; datasety plikowe; właściciel skopiował plik z migawki, pve9 10-18); zvol (VM) „light” -- ZROBIONE (partycje NTFS/ext4/xfs/vfat/exfat/btrfs tylko do odczytu, LUKS i BitLocker po podaniu klucza; LVM/RAID -- nie); łańcuch C->A z pominięciem B -- NIE w 1.0 (właściciel 10-18: to odzysk z innego kolektora; jest odzysk z ręcznej kopii, odzysk z ręcznie podłączonego kolektora -- po 1.0) | w toku |
| C | Retencja | wada `[prune:]` gubi `gfs=yes` -- ZROBIONE #610 (drabina `-G` na szczebel po stronie źródła; lądowiska płaskie; migawki zdalne przyjmują GFS). Retencję źródła okno relacji już pokazuje; `audit-source-retention` to jednorazowa migracja hosta -- CLI | zrobione |
| D | Replika | `purge-replica-copy` -- USUNIĘTY z pakietu (właściciel 10-18: „nie chcemy tego”; dysk czyści formatowanie w „Dodaj dysk”); `remove-media-trigger` -- ZROBIONE w oknach (plan zmiany/usuwania repliki zdejmuje regułę, gdy żadna replika nie rusza po włożeniu) | zrobione |
| E | Suity | `test/tui` z selektorem sekcji; przegląd duplikatów w `zfsbackup`/`localbackup` (165 s i 143 s w CI); zmiana klawisza/ekranu nie ciągnie całego drzewa | do zrobienia |
| G | Porządek paneli | U21: jedna reguła lista / prawy panel / dolny panel z zakładkami na F2-F6 i F11; F4 jako „Historia”; F11 pokaże zgodę źródła przed oknami (U14) | zrobione; zgoda źródła -- w U14 |
| F | Uwagi z obserwacji | wpisy U1.. poniżej, zbierane do najbliższej paczki | otwarte |

Tylko CLI (świadomie, bez okna): `setup-server` (instalacja hosta), `move-to-client`,
`final-catchup`, `pause-writers`/`resume-writers` (deploy), `show-scope`, `test`, `help`,
`audit-source-retention` (migracja hosta).
Do decyzji właściciela, jeśli któreś ma mieć okno.

## Uwagi właściciela (U1..)

| # | data | słowa właściciela / co | paczka | stan |
|---|---|---|---|---|
| U1 | 2026-10-18 | „Wszedłem do migawki i skopiowałem plik do /mnt” -- Przeglądaj kopię działa na żywo | B | potwierdzone |
| U2 | 2026-10-18 | „purge-replica-copy -- nie chcemy tego. Można sformatować dysk w innej opcji” | D | zrobione |
| U3 | 2026-10-18 | C->A „nie implementujemy teraz… odzysk z ręcznie podłączonego kolektora, ale nie w 1.0” | B | zapisane |
| U4 | 2026-10-18 | „remove-media-trigger -- konieczne… rozumiem, że to był ruch w jedną stronę?” -- tak; teraz zdejmowana w oknach | D | zrobione |
| U5 | 2026-10-18 | „Wyłącz w GUI -- tak, ale z wyjaśnieniem, co to implikuje i jak włączyć z powrotem” | A | zrobione |
| U6 | 2026-10-18 | zvol w Przeglądaj kopię „light”: NTFS, EXT4 i inne znane; BitLocker/LUKS -- podanie klucza | B | zrobione (BitLocker bez testu na żywo) |
| U7 | 2026-10-18 | „F8 … klawisz w przełącza na Wyłącz -- fajnie, ale te klawisze powinny być na ramce na dole koło wykonaj, a nie w treści okna -- chaos znowu. Nie uczysz się.” Na jutro: w oknach potwierdzenia klawisze TYLKO na dolnej ramce (`t wykonaj  w wyłącz  Tab …  Esc …`), z treści usunąć wiersz „t = wykonaj …” i „w = …”; przejrzeć wszystkie okna pod tym kątem -- ZROBIONE (potwierdzenie, F8, pole tekstowe, eksport/import, formularz, panel F11; okna whiptail nie mają własnej stopki -- tam podpowiedź zostaje w treści) | F | zrobione |
| U8 | 2026-10-18 | „Musiałem przejść całą ścieżkę repliki, żeby wybrać »nie« przy »uruchom po włożeniu« -- kreator jest do bani. Ekran do przebudowy. Check box powinien mówić, że ta opcja jest włączona lub nie.” Zmiana repliki = jedno okno z obecnymi ustawieniami (m.in. pole wyboru „po włożeniu dysku: [x]”), zmiana jednej rzeczy bez przechodzenia całego kreatora -- ZROBIONE (właściciel 10-19 zaakceptował listę: Źródła, Na dysku, Nośnik, Kiedy, [x] Po włożeniu, silnik, od nowa, Zapisz) | F | zrobione |
| U9 | 2026-10-18 | zrzut: „Nie udało się zamontować /dev/zd96 (96M)” -- w menu partycji był sam dysk (puste pole `lsblk -r` przesuwało kolumny) | B | zrobione |
| U10 | 2026-10-18 | zrzut: „Device /dev/zd96p1 does not exist” -- równoczesny mój test zdjął `snapdev`; dwa przeglądania jednego dysku przeszkadzały sobie | B | zrobione (znaczniki per dataset) |
| U11 | 2026-10-19 | „GOTOWE: replika usb1 zainstalowana … albo teraz: F7 na F6 -- co to znaczy F7 na F6? To jest niezrozumiałe” -- teraz pełne zdania („ekran Replika (klawisz F6), zaznacz replikę i naciśnij F7 (Uruchom teraz)”); poprawiony też komunikat importu („F8 na F3” -> „ekran Relacje, F9 Plik -> Eksport”) | F | zrobione |
| U12 | 2026-10-19 | „Powrót do GUI trwa wszędzie długo. Może da się to poprawić.” (po Przeglądaj kopię) | F | zrobione (odświeżanie w tle) |
| U13 | 2026-10-19 | „ESC po wywołaniu okna F7 uruchom długo wraca do GUI” | F | zrobione (to samo) |
| U14 | 2026-10-19 | odzysk `g3-bc` na miejsce i obok: odmowa, bo źródło (pve11) nie wydało zgody (`deploy.sh --allow-restore=pve9 [--replace]`). Działa zgodnie z projektem, ale okno puściło całą drogę i odmówiło dopiero polecenie, po angielsku. Do zrobienia: okno Przywróć sprawdza zgodę przed krokami i mówi po polsku, co zrobić na źródle; opcja „na tym hoście” (bez zgody źródła) | B | zrobione (`finisz/U14-U16-U20`) |
| U15 | 2026-10-19 | „2 of 28 prune lines carry NO -L” w odzysku -- liczył linie repliki i `#on-insert` | B | zrobione |
| U16 | 2026-10-19 | usuwanie `solab` z obiema opcjami sprzątania: stop po kolektorze, bo pve9 nie ma roota do pve10; w środku pełny wydruk wdrożenia. Do zrobienia: okno Usuń sprawdza dostęp roota do źródła przed startem i mówi po polsku, co zrobić ręcznie na źródle (albo „tylko kolektor”); wydruk bez faz wdrożenia | A | zrobione (`finisz/U14-U16-U20`) |
| U17 | 2026-10-19 | zrzut „Nie da się zmienić 'solab' -- removed” -- stan spójny po U16: kolektor usunięty, rekord czeka; domknięcie: `deploy.sh --leave=pve9` na pve10 i Del jeszcze raz | A | wyjaśnione |
| U18 | 2026-10-19 | „Dla relacji ciąg: wyeksportuj, usuń, zaimportuj, wykonaj się powiódł” | A | potwierdzone |
| U19 | 2026-10-19 | Zmień relację `g3-bc`: po wyborze datasetu od razu „wykonaj” -- „do bani to jest i do przebudowy”. Do zrobienia: okno zmiany relacji jako lista pól (wzór U8), symulacja przed kodem | A | do zrobienia |
| U20 | 2026-10-19 | add-source na lustrze `g3-bc` kończy się porażką: rekord bez `REQUESTED_DATASETS`, źródło (pve11) ma już w zakresie korzeń nadrzędny, activate odmawia nadmiarowych. Do zrobienia: add-source dla lustra aktualizuje rekord i uznaje korzeń nadrzędny już w zakresie | A | zrobione (`finisz/U14-U16-U20`) |
| U22 | 2026-10-19 | „A co ze zmianą IP hosta z punktu widzenia kolektora po przeniesieniu kolektora za VPN?” -- jest (okno „Adres hosta”, 10-17), dowód tylko pull pve10 -> pve9b na drugi adres. Do zrobienia: lab dla lustra (druga strona też łączy się z kolektorem) i push | A | do sprawdzenia |
| U21 | 2026-10-19 | „F2 i F4 -- nie wiem, czym się różnią”, „prawy i dolny panel -- logika i porządek, nie dublować”. Reguła: lista = wybór i stan; prawy panel = fakty o zaznaczonym, których nie ma w liście; dolny = dzieci w zakładkach (F3 Datasety/Zadania), Tab wchodzi, prawy panel idzie za kursorem. Symulacja wszystkich ekranów zaakceptowana, kod jedną paczką | G | zrobione (`finisz/panele`) |
