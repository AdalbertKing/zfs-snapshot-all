# Kampania marudnego admina -- 2026-10-29/30 (noc)

Polecenie właściciela: „Zrób ostateczną kampanię marudnego admina. Wszystkie opcje. Cała noc.
Tworzenie relacji, zmiana, eksport, usuwanie, import. Z szablonu, z palca. Potem repliki, to samo
… Sprawdzaj powroty do okna wyżej, ile to trwa. Eliminuj zbędne ciągi „czy na pewno” … Zbadaj
koniecznie antyransomware guard, strażnika przeniesienia vm na replikę i strażnika przepełnienia.”
Dopisek w trakcie: „przywracanie z replik i kopii. Częściowe i całościowe. Z punktu czasowego
i najnowsze.”

## Jak

- Lab zamiast produkcji: „pve1<pve2<>pve3” = pve9 (źródło) → **pve10** (kolektor) ↔ pve11
  (lustro), pve9b drugie źródło (przez VPN 10.98.0.2). Metropolis nietknięte.
- Cały lab na jednej gałęzi labowej `lab/1004-1005` (PR #1004 + #1005 + poprawki tej kampanii,
  nigdy do main), `update-hold` na każdym hoście.
- GUI sterowane przez tmux na pve10 (`/root/kamp/drv.sh`): każdy krok czeka na tekst okna i mierzy
  czas od klawisza do gotowego ekranu; dziennik `/root/kamp/log.txt`, zrzuty `/root/kamp/shots`.

## Co przeszło (na żywo)

| obszar | scenariusze | wynik |
|---|---|---|
| Relacje | eksport; import identycznej; usunięcie (z rozmyśleniem się: Esc, potem jeszcze raz); import z pliku po usunięciu; kreator z szablonu (zły adres → komunikat w 3,5 s, adres VPN, „Nikt -- resztki”, cel, szablon, retencja źródła z palca, poprawka z podsumowania); kreator „Migawki lokalne” z tabelą „Ręcznie”; zmiana: +dataset, harmonogram ręczny (+tygodniowe), silnik (gzip), jeden zapis | działa po poprawkach K5, K14 |
| Odzysk | z kopii na tym hoście, całość, punkt 20:01; na miejsce na źródło, część (mail), najnowsza; obok oryginału, całe drzewo, punkt 22:01; z dysku repliki, punkt 12:46; na miejsce zamontowanego datasetu | wszystkie spójne; zamontowany → odmowa z listą i poleceniami dla roota, nic nie zmienione |
| Repliki | nowa (własny cron, na puli `kampcap`); zmiana usb9 (po podłączeniu: tak); podłączenie nośnika `udevadm trigger --action=add sdc1`; porzucenie zmiany; usunięcie | działa po poprawkach K27–K29 |
| Strażnik przepełnienia (T2) | pula 2 GB na zvolu, migawki 200 MB, jedna pod hold, `__replicate_`, ręczna; 90% | **zaliczony**: usunął najstarszą wolną, 79%; hold, `__replicate_`, ręczna, 2 najnowsze zostały; alarm w kolejce; drugi bieg nic |
| Strażnik przyrostu (T3) | historia małych przyrostów, potem 250 MB losowych; kontrole: zera, 300 MB tekstu | **zaliczony**: 9,3× normy, kompresja 1,00 → ALARM + mail; raz; tekst 31× normy z kompresją 30 → bez alarmu |
| Strażnik gościa PVE (T4) | CT 902 w drzewie `kampcap/data`, config przeniesiony do węzła `pvefake` | migawka `-R`: dysk gościa pominięty + WARN; **porządki: przed K20 szły po dysku repliki (rc 0)**, po poprawce NOT RUN rc 76; gość wraca → biegnie |

## Czasy (pve10, ms)

| krok | czas |
|---|---|
| start GUI: ekran / monitor i przebiegi | 1 100–2 100 / 11 600–18 500 |
| przełączenie F2–F6, otwarcie okien, kroki kreatora | 8–220 (Del relacji: 840–3 300 -- plan i sprawdzenie źródła) |
| eksport relacji | < 1 000 |
| usunięcie relacji | 19 600–38 800 |
| utworzenie relacji (backup, 2 datasety) | 80 500–84 700 |
| utworzenie relacji „Migawki lokalne” | 23 200 |
| import relacji (po poprawce raw) | 47 400 |
| zmiana relacji (3 zmiany) | 66 700 |
| odzysk: lokalnie / na miejsce / obok / z repliki | 6 500 / 7 800 / 30 300 / 5 800 |
| nowa replika / zmiana repliki / usunięcie repliki | 9 500 / 9 500 / 12 400 |
| zmiana relacji: tabela „Ręcznie” → Dalej, Silnik → Gotowe | 5 800–7 000, 6 400 (K33, K35) |

## Znaleziska

Waga: A = błędny wynik / utrata danych / zła decyzja; B = zbędny krok, myląca informacja,
strata czasu; C = kosmetyka. „Naprawione” = na gałęzi `fix/kamp-1030` (PR), nie na main.

| # | gdzie | co | waga | stan |
|---|---|---|---|---|
| K5 | import relacji z zaszyfrowanym źródłem | eksport bez `--raw` (raw włączony przez set-transfer jest tylko w configu); import robił pierwszą kopię bez `-w`, cel odmówił, relacja w `seeding` | A | **naprawione** (eksport bierze raw z sekcji; import starego pliku dokłada `--raw`) |
| K14 | kreator, „Nikt -- resztki”, 2+ datasety | podsumowanie „robię własne (`--own-snapshots`)”, komenda bez flagi (`build_argv` z `IFS=,` psuł porównanie); kopia lokalna „łańcuch” gubiła `--passive` | A | **naprawione** |
| K20 | strażnik gościa PVE, porządki drzewa | `-P "__replicate_:2"` brane za źródło; drzewo nie listowane, prune po dysku repliki pvesr | A | **naprawione** (PG19b) |
| K27 | nowa replika → „Sformatuj nowy nośnik” | na liście jedyny dysk = nośnik repliki usb9 („UWAGA: ma pulę”), jeden Enter od wyczyszczenia | A | **naprawione** |
| K29 | nowa replika, własny cron po błędzie | po „Zły harmonogram” powrót do MENU z „auto” -- Enter dawał auto po cichu | A | **naprawione** (powrót do pola) |
| K28 | nowa replika, własny cron | „61 25 * * *” przyjęte (tylko liczba pól) | B | **naprawione** (zakresy) |
| K15 | kreator relacji: sukces | okno z Ok (druga linia „Dziennik:”) | B | **naprawione** |
| K2 | eksport | udany eksport zostawiał okno WYJŚCIE | B | **naprawione** (czysty sukces zamyka okno, zdanie na linii komunikatu) |
| K3 | import identycznej relacji | „nic do zrobienia” w oknie | B | **naprawione** (linia komunikatu) |
| K4 | POTWIERDZENIE (curses) | Enter zamykał jako „anulowano” (import przepadł) | B | **naprawione** (Enter zostaje w oknie) |
| K7 | okno wyjścia | nie śledziło końca: wynik rc=1 importu poza ekranem | B | **naprawione** |
| K9 | kreator „Źródło gotowe” | okno z samym Dalej, gdy wszystko OK | B | otwarte -- usunięcie przesuwa odpowiedzi w kilkudziesięciu sekwencjach testów kreatora |
| K13 | kreator „Nazwa relacji” | okno z samym Ok (nazwa = host) | B | otwarte (jak K9) |
| K19 | monitor lustra (sync z łańcuchem) | `client_section_plan` pisze w sekcji stałe `monitor_warn = 3h`, `monitor_crit = 5h` (zfs-backup.sh 4977–4978; komentarz 4964–4968: progi pod rytm łańcucha godzinowego). Pole sekcji wygrywa z progiem szablonu, więc dostaje je też monitor szczebla dobowego (`target_monitor = 30h 48h` w configu) -- na pve10 w kolejce alertów CRITICAL dla dobowych pve11 przy age=13h | B | otwarte -- poprawka = próg szczebla + jeden przeskok, zmienia generator i wzorce |
| K23 | F4 na kopii → F9 Przywróć | drzewo zaznacza CAŁĄ relację, nie kopię spod kursora | B | otwarte |
| K25 | odzysk na miejsce | GUI pisze „Odzysk: gotowe”, choć dataset jest „not mounted”; tę informację ma tylko dziennik | B | otwarte |
| K32 | zmiana relacji, tabela „Ręcznie” | podsumowanie „tabela [zmiana]” nie mówi, co (np. wyłączony dobowy) | B | otwarte |
| K33, K35 | zmiana relacji | tabela → Dalej 5,8–7 s, Silnik → Gotowe 6,4 s, bez okna „liczę” | B | otwarte |
| K34 | zmiana relacji, tabela zmieniana dwa razy | plan „daily dropped + added” mimo końcowej tabeli = config (różnica od stanu sesji) | B | otwarte |
| K36 | długi plan (whiptail `--textbox`) | Enter nie naciska Dalej, trzeba Tab | B | otwarte |
| K10 | drzewo datasetów (kreator relacji) | Spacja: [x]→[-]→[ ]; dwa naciśnięcia = dataset nadal wybrany | B | otwarte |
| K1 | F4 lista | Relacja ucięta, Kopia z pustym miejscem | C | otwarte |
| K6 | import (źródło nie zna kolektora) | pusty `hdd/backups/<IP>` obok właściwego lądowiska | C | otwarte (zbiór na pve10 zostawiony jako dowód) |
| K8 | kreator, adres hosta | znane hosty nie są podpowiadane | C | otwarte |
| K11 | kreator | „krok 2 z 7” → „krok 4 z 8” | C | otwarte |
| K12 | lista szablonów | „1 lat” | C | otwarte |
| K16–K18 | kreator „Migawki lokalne” | „W CELU KOPII”, „z configu tej relacji” (nowej), „skopiują się” | C | otwarte |
| K21, K22 | odzysk | adres zamiast nazwy hosta; „z dysku” przy kopii relacji | C | otwarte |
| K30 | nowa replika: GOTOWE | okno z treścią (jak zrobić pierwszą kopię) -- zgodne z zasadą | C | -- |
| K31 | menu zmiany (relacji, repliki) | linia „────” wybieralna | C | otwarte |
| K37 | usunięcie relacji lokalnej | „the pairing with  stays” -- pusta nazwa | C | otwarte |

Obserwacje (nie wady): strażnik przepełnienia nie ruszy na bardzo małej puli -- zmierzone: pula
240 MB zgłaszała „No space left” przy zajętości 50% (zapas, który ZFS trzyma dla siebie), więc 89% nie
zapada nigdy; na puli 2 GB próg osiągnięty; po podłączeniu nośnika ruszają wszystkie repliki „po
podłączeniu”, których nośnik jest obecny -- w labie `replab` i `gwlive` to pliki, zawsze obecne.

## Stan labu po kampanii

- pve9, pve9b, pve10, pve11: gałąź `lab/1004-1005` z poprawkami tej kampanii, `update-hold`.
  Powrót na kanał wydań: `bash /root/lab-dev.sh off` na każdym.
- pve10: relacje pve9 (zaimportowana), pve9b (założona kreatorem: data, db, home; godzinowe,
  dobowe, tygodniowe; gzip), pve11, lokalna-hdd-solab-c; repliki usb1, usb9 (po podłączeniu:
  tak), calapula. Strażnicy przepełnienia i przyrostu wyłączeni (jak przed kampanią).
- Usunięte po testach: relacja i pula `kampcap`, zvole, gość 902 i węzeł `pvefake`, zbiory
  odzyskane w testach; zgoda na odzysk na pve9b cofnięta.
