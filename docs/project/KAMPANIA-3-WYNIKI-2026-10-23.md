# Kampania 3 -- wyniki i lista testów dla właściciela (2026-10-23)

Plan: `KAMPANIA-3-PLAN-2026-10-23.md`. Wszystko na lab (pve9/pve10), na żywo w tmux.
pve10 (root i zfsbackup) stoi na `main` acb385ec.

## Scalone (22.10, #745-#767)

| PR | co |
|---|---|
| #756 | szablony: `default` płaski h24 d7 w4 m3, nowy `full` h24 d7 w4 m12 y5, na liście pięć: default, full, d7h24, d30h24, m12w4d7h24-gfs (reszta ukryta, pliki zostają) |
| #758 | dataset dołączany do istniejącej relacji kopiuje sekcje sąsiada -- plik szablonu nie jest czytany |
| #752, #759 | eksport/import bez pliku szablonu; REV-168 (czytnik JSON z ucieczkami) -- czeka na recenzenta |
| #760 | host zaczynający się od `-` odrzucany (rux, deploy, kreator) |
| #761 | F7 dwa razy = „busy”, nie błąd; lista szablonów czytelna przy 80×24 |
| #762 | pomoc F1 zawijana zamiast ucinana |
| #763 | F2/F3 „Następny” = to, co naprawdę jest w cronie (był harmonogram bloku, nie rozłożony) |
| #764 | prawa ramka okien w ogóle nie trafiała na ekran (od września); pomoc bez sierot; listwa F4 mieści się w 80 |
| #765 | nowa nazwa relacji/repliki/szablonu nie zaczyna się od `-` ani `.` |
| #766, #767 | słowa: „myślnik” wszędzie, „Wstecz”, „(utworzone, jeśli go nie ma)”, bez ścieżek klawiszy w treści dwóch okien |

## Bloki kampanii

- **A tam i z powrotem:** czysto. Ślady (bez szkody, zapisane): rekord rośnie (dopisywanie, wygrywa ostatni),
  w configu zbierają się puste linie, migawka startowa relacji lokalnej zostaje na źródle, pusty katalog celu zostaje.
- **B panele a prawda:** „Następny” naprawione (#763). F2 na żywo: ab pobranie 22:16 = cron :16.
- **C przerwane w połowie:** odcięta sieć w trakcie dodawania źródła -- config nietknięty, powtórka kończy.
  Zabita replika w trakcie -- nośnik odpięty, następny bieg wznawia z tokenu.
- **D równoległość:** F7 dwa razy (#761). Zmiana szczebli w trakcie biegów -- działa.
- **E złe wejście:** metaznaki powłoki odrzucane; host i nazwa z `-` (#760, #765).
- **F terminal:** 80×24 -- lista szablonów, pomoc, ramki, listwa (#761, #762, #764).
- **G klawisze:** litera na liście jest widoczna w linii poleceń zanim Enter ją wyśle (`$ e_`) -- zgodnie z
  zamysłem. Usuwanie relacji: „SKASUJ KOPIE” domyślnie odznaczone.
- **H słowa:** przegląd `text-checker` wszystkich okien; drobne poprawione (#766, #767), reszta w „Zanotowane”.
- **I odmowy:** zajęta nazwa, brak `--name`, brak datasetu/profilu, cel w źródle, nakładanie z rekursywnym
  `[dataset:hdd/lab]` -- wszystkie mówią co i dlaczego, nic nie zmieniają.
- **J pomoc:** klawisze z F1 mają obsługę; pomoc nie wymienia kilku liter okien (np. `d` dokończ w oknie relacji).

## Zanotowane, nie poprawiane (do decyzji)

1. Po każdym oknie (kreator, usuwanie) linia komunikatu pokazuje „[rc=1] <cała linia polecenia>”, także po
   zwykłym Esc -- anulowanie wygląda jak błąd. Słowo okna („przerwane, nic nie zmieniono”) ginie z ekranem.
   Poprawka dotyczy wszystkich okien -- czy robić?
2. Krok „Jak długo trzymać”: przy 100 kolumnach wiersz `full` kończy się „5…” (5 lat), przy 80 ucina się więcej.
3. Kreator kopii lokalnej proponuje nośniki replik (gwlive, replab) jako źródła.
4. „zfsbackup (zostanie utworzone)” przy istniejącym koncie.
5. Plan importu wypisuje argumenty bez cudzysłowów; plany czasowników po angielsku.
6. Dziecko odtworzone jako raw staje się własnym korzeniem szyfrowania.
7. Esc w kroku 1 kreatora repliki wychodzi bez pytania.
8. Prawy panel F2 przy 80 kolumnach ucina ścieżkę („hdd/backups/192.16”).
9. Stopki mieszają tryby: „Enter wybiera   Esc wraca” obok „Enter dalej   Esc wróć” -- który ma zostać?
10. Panele F3/F6 i kilka komunikatów nadal podają drogę klawiszami w treści („F3 Relacje, Enter, e zmień”,
    „(Enter na polu Szablon)”). To wskazówki do innego okna, nie klawisze tego okna -- czy też je usunąć (E88)?
11. Kreator pokazuje angielską odmowę czasownika w cudzysłowie („This host reads as FLAT”); etykieta
    „replica copy (%s)” po angielsku w statystykach.

## Decyzje 23.10 -- wykonane (#774-#782)

| punkt | co | PR |
|---|---|---|
| 1 | po oknie linia komunikatu niesie słowo okna („Usuń relację: przerwane, nic nie zmieniono”), nie „[rc=1] <polecenie>” | #774 |
| 9, 10, 11 | stopki „Enter wybiera   Esc wraca”; bez dróg klawiszy w treści; bez angielskiego cytatu | #775 |
| 3 | kopia/migawki lokalne bez nośników replik jako źródła | #776 |
| 2 | lista szablonów bez „trzyma” (przy 100 kolumnach mieści się cała); przy okazji panel „Trzyma” dla pobrania | #778 |
| 7 | Esc w kroku 1 nowej repliki pyta (Przerwij / Zostań) | #779 |
| 5 | plan importu i tekst eksportu w cudzysłowach powłoki (`%q`); plany CLI zostają po angielsku | #781, #782 |
| 4 | już zrobione wcześniej (#766) | -- |
| 8 | fałszywy alarm: ścieżka zawija się w kolejny wiersz | -- |
| 6 | odzysk raw: przy `--deny-restore` zbiór dostaje klucz z powrotem (`load-key`, pod zaszyfrowanym rodzicem `change-key -i`) | #783 |

**Punkt 6 -- decyzja „automatycznie”, wykonane.** Klucz jest tylko u roota na odzyskiwanej maszynie, więc
robi to `deploy.sh --deny-restore` (zamknięcie grantu po odzysku). Na żywo pve9: `hdd/enc/docs2` dziedziczy
`hdd/enc`, `hdd/restore/docs-raw` otwiera się kluczem oryginału, zbiór z innym kluczem nietknięty. Nie obejmuje
odzysku lokalnego (kolektor na sam siebie).

Recenzja w międzyczasie: REV-169 (izolacja suity localbackup) zamknięty; REV-170 (P1: cofnięcie jednego
grantu Restore odbierało wspólne `<pula>/restore` drugiemu) naprawiony w #780, czeka na recenzenta.

## Sprzątanie labu (zostało)

- replika usb9 na dysku scsi2 VM 111 na **pve2** (produkcja -- zdejmę po twojej zgodzie);
- relacja pve9 (hdd/enc, raw), `/root/enc-w2.key` na pve9; linie U50 i gwlive; hdd/restore/archive;
  sierota hdd/backups/192.168.28.99/hdd/data; `/root/state-snaps`.

## Lista testów dla ciebie

PuTTY `root@192.168.28.97`, `zfs-backup gui`. Okno PuTTY najpierw 80×24, potem dowolne.

1. **Ramki:** każdy ekran F2-F6, F11 ma prawą krawędź okna (`╗ ║ ╝`).
2. **F1** przy 80×24: tekst zawinięty, bez „…” w środku zdania, bez pojedynczych słów w wierszu.
3. **F4:** listwa klawiszy kończy się na „12Wyjdź”, nic nie ucięte.
4. **F2, relacja ab:** kolumna „Następny” dla pobrania = :15/:16, nie :01.
5. **F7 dwa razy szybko** na tej samej relacji: drugi bieg mówi „busy”, nie „did NOT finish”.
6. **F5:** pięć szablonów -- default, full, d7h24, d30h24, m12w4d7h24-gfs; Enter na `default`: h24 d7 w4 m3, płaski.
7. **F3, Ins, Migawki lokalne:** w kroku „Jak długo trzymać” znacznik `[N najnowszych]`/`[GFS]` stoi zaraz za nazwą.
8. Ten sam kreator, krok „Nazwa relacji”: wpisz `-x` -- „Zła nazwa”; wpisz `.x` -- to samo; Wstecz, Esc -- nic nie powstało.
9. **F3, ab, Enter, `e` -- Datasety:** dodaj dataset do ab; plan nie wspomina pliku szablonu; po zapisie F2 pokazuje nowy dataset z godziną zgodną z `crontab -l`.
10. **F3, ab, F9 eksport**, potem import na drugim hoście bez pliku szablonu -- import przechodzi, relacja ma swoje szczeble.
11. **F3, Del na ab:** „SKASUJ KOPIE” odznaczone; Wstecz -- relacja zostaje (zobacz, co pokazuje linia komunikatu -- punkt 1 z „Zanotowane”).
12. **F11 odzysk zaszyfrowanej kopii** (pve9 hdd/enc): wraca jako raw, klucz nie jest potrzebny do odtworzenia.
13. **Kreator Backup ze źródłem zaszyfrowanym:** bez wchodzenia w Zaawansowane karta mówi „zaszyfrowane” (raw).
14. **Host z myślnikiem** w kreatorze Backup (`-oProxyCommand=x`): odmowa w kroku hosta.

Recenzja: REV-168 czeka na recenzenta (`IMPLEMENTED | Reviewer`), innych otwartych nie ma.
