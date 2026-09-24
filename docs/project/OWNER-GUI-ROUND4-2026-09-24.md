# GUI, runda 4 — uwagi i decyzje właściciela (2026-09-24)

Zebrane po wgraniu `main` 3084d871 (#430, #431) na pve10 i pve11. **Stan: zebrane,
nie zakodowane.** Kodowanie rusza na polecenie właściciela ("koduj").

Zasada nadrzędna bez zmian: **proste, intuicyjne GUI bez udziwnień**
(`OWNER-DECISIONS.md`).

## R4-1 + R4-2 — klawisze F

- **Błąd:** na F3 klawisz F4 włącza pauzę zamiast przejść do okna Transfery
  (`tui/zfs-tui.py`, wyjątek `k == "F4" and self.screen == "relacje"`).
- **Błąd (#430, #431):** `u` na F4 i `s` na F2 są martwe w prawdziwym GUI. Pętla
  curses oddaje każdy drukowalny znak do linii poleceń (`text:u`), zanim ekran go
  zobaczy. Testy szły przez `--render-once --keys u`, które tę pętlę omija.
  Litery zostają dla linii poleceń (bash) — tak ma być.
- **Decyzja:**
  - F1 pomoc, F2–F6 główne okna, F10 wyjście.
  - **F7 / F8 / F9 — akcje zależne od okna**, podpisane w dolnej listwie (styl mc).
  - **Odśwież przechodzi z F9 na F5** (F5 wolne po zniesieniu Monitora).
  - F3 Relacje: F7 pauza/wznów, F8 eksport, F9 import; Del i Ins bez zmian.
  - F4 Transfery: F7 ukryj/pokaż transfery usuniętych relacji.
  - F2 Zadania: F7 sortowanie.
- **Test musi iść przez pętlę klawiszy** (pty), nie przez `--keys`.

## R4-3 — odstępy F2

Za ciasno między Kierunkiem a Zadaniem. Co najmniej dwie spacje między kolumnami.

## R4-4 — kolumna Zadanie rozbita na cztery

`hourly` w „pobranie hourly” to nazwa rodziny migawek (u profili nazwana od
szczebla), nie częstotliwość; częstotliwość pokazuje Harmonogram. `x2` to liczba
datasetów w zgrupowanym wierszu. **Decyzja:**

| Zadanie | Prefiks | Trzyma | szt. |
|---|---|---|---|
| pobranie / wysyłka / lokalny prune / zdalny prune | rodzina migawek | liczba z `-H24` itd.; `-` dla transferu | datasetów w grupie |

„porządki” → **lokalny prune**, „porządki źródła” → **zdalny prune**. Przy 100
kolumnach Czas i GB spadają z listy (są w panelu) — zaakceptowane.
Do ustalenia przy kodowaniu: Prefiks ma pokazywać to, co operator widzi w
`zfs list` (`automated_hourly`, nie samo `hourly`).

## R4-5 — wolne miejsce w F2

Przy szerokim terminalu kolumny są upchane w lewo, a prawa część listy stoi pusta.
Zapas szerokości rozdzielić równo na odstępy między kolumnami.

## R4-6 + R4-7 — jedno okno szczegółów, trzy wejścia

- Enter na parze w dolnym panelu F3 **nie skacze już do F2** (mylące, bez powrotu).
- Enter na zadaniu F2, Enter na parze F3 i Enter na relacji F3 otwierają okno
  **tego samego układu**: szczegóły, pod nimi sekcja **CONFIG**, potem **CRON**,
  przewijane. Zakładki Opis/Config/Cron z R3-2 znikają.
- Okno zadania/pary pokazuje config i cron zawężone do tego zadania/pary.
- Esc wraca w to samo miejsce.

## R4-8 — eksport bez drugiego potwierdzenia

Po wpisaniu ścieżki Enter od razu zapisuje plik; `t` przy eksporcie znika.
Plik już istnieje → **nadpisać bez pytania**. `t` przy imporcie (zgoda źródła)
zostaje.

## R4-9 — import: wybór pliku z listy

Zamiast wpisywania ścieżki lista w stylu menedżera plików: `..`, katalogi, pliki
eksportu (najnowsze pierwsze, z datą i nazwą relacji z pliku). Enter na katalogu
wchodzi, na pliku importuje (dalej werdykt jak dziś). Ostatnia pozycja: „wpisz
ścieżkę ręcznie”.

## R4-10 — miejsce plików eksportu

**Decyzja:** `/etc/zfs-snapshot-all/relations/`, obok profili użytkownika
(`/etc/zfs-snapshot-all/profiles`, `PROFILE_USER_ROOT`). Poza checkoutem, więc
nie trafia na GitHub i `git pull` go nie nadpisze. Eksport zapisuje tam
domyślnie (dziś `$HOME/<relacja>.export.json`, zależne od konta), lista z R4-9
startuje tam. `profiles.local/` w repo odrzucono 2026-08-04 (kilka kopii pakietu
na hoście). Do ustalenia: prawa zapisu dla konta `zfsbackup`.

## Poza rundą — wycena portu na Pythona (tylko szacunek)

Produkt: ~26,5 tys. linii kodu bash → ~17–20 tys. w Pythonie. Testy (31,6 tys.)
zostają jako czarna skrzynka. Rekomendacja: nie całość; ewentualnie część
sterująca (`zfs-backup.sh`, `gen-cron.sh`, `deploy.sh`), silniki transferu
zostają w bashu. Najwcześniej po dokończeniu GUI i P-0. Nie jest to decyzja.
