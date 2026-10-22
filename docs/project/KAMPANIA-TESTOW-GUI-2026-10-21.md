# Kampania testów GUI przed 1.0 — 2026-10-21

Cel: przejść całe GUI tak, jak przejdzie je administrator, i spisać uwagi
o funkcjach i wyglądzie. Potem zbiorcza poprawka i zamknięcie 1.0.

Wejście: PuTTY `root@192.168.28.97` (pve10, kolektor), `zfs-backup gui`. Do
pve9 / pve9b / pve11 wchodzisz tak samo (.99 / .98 / .96), gdy scenariusz mówi
„na źródle”. pve10 aktualizuje się sam co godzinę z `main`; niczego nie
wdrażam ręcznie w trakcie twoich testów.

## Uwagi — jak zapisywać

Numeruj **G1, G2, …** i przy każdej podaj:

- ekran / okno (np. „F3 Relacje, okno Zmień relację”);
- co zrobiłeś (klawisz, wybór);
- co zobaczyłeś, a co byś chciał zobaczyć;
- rodzaj: **F** (funkcja nie działa / działa źle), **W** (wygląd, tekst,
  układ), **P** (pomysł).

Zrzut ekranu z PuTTY wystarczy wkleić. Uwagi spisuję do
`docs/project/FINISZ-BACKLOG.md` i robię paczkami na koniec.

## Stan labu (sprawdzony 2026-10-21)

| host | adres | rola | datasety (najważniejsze) |
|---|---|---|---|
| **pve10** | .97 | kolektor | `hdd/archive`, `hdd/labbrowse` (zvole: ext4, NTFS, LUKS), kopie `hdd/backups/192.168.28.98/...`, `hdd/lab` (kopia z pve11) |
| **pve9b** | .98 | źródło „a” (przez VPN 10.98.0.2) | `hdd/data` (docs, mail, photos), `hdd/home` (adam, ewa), `hdd/vms` (vm1-3), `hdd/db`, `hdd/ct`, `hdd/vm-disks` |
| **pve11** | .96 | źródło „c” i kolektor „bc” | `hdd/lab` (ct-201, srv-a, srv-b, vm-101), `hdd/labbrowse`, `hdd/vm` |
| **pve9** | .99 | **wolny** -- bez relacji; ma replikę na dysk wymienny | `hdd/data` (vm1-3), `hdd/lab` (ct-201, srv-a, srv-b, vm-101), `hdd/archive` |

Relacje, które już stoją (pve10 widzi je w F3 Relacje):

| relacja | kierunek | co | harmonogram |
|---|---|---|---|
| `relacja-ab` | pve9b → pve10 (VPN) | `hdd/data`, `hdd/home`, `hdd/vms` | co godzinę :01/:21, dobowa 01:11 |
| `relacja-cb` | pve11 → pve10 | `hdd/lab` | jw. |
| `relacja-bc` | pve10 → pve11 | `hdd/archive`, `hdd/labbrowse` | jw. |

Replika: pve9, `usb1`: `hdd/data` → pula `repl` na dysku wymiennym, w piątek
22:00. Dyski wymienne na pve9 to dyski wirtualne (`sdc`, `sdd`, po 2 GB):
„włożenie” i „wyjęcie” zrobię na twoje hasło (odpięcie / podpięcie dysku od
strony hypervisora), bo fizycznie nie ma czego wkładać.

**Proponuję:** scenariusze niszczące (usuń, import) rób na **nowej** relacji
pve9 → pve10 z bloku B. `relacja-ab` przez VPN zostaw na koniec: odtworzenie VPN
kosztuje dużo więcej niż sama relacja.

## A. Rozgrzewka — tylko patrzenie (10 min)

1. Każdy ekran z paska po kolei: F2 Zadania, F3 Relacje, F4 Historia, F5 Szablony,
   F6 Replika, F11 Odzysk, F10 Ustawienia, F1 Pomoc. Czy pasek górny mówi, gdzie
   jestem i co jest ważne? Czy tabele się mieszczą w oknie PuTTY?
2. F3: trzy relacje powyżej. Wejdź w każdą (Enter): szczegóły, ostatni
   transfer, wiek kopii. F2 Zadania: te same relacje rozpisane na zadania crona.
3. F4 Historia: czy widać, co szło ostatnio i czy się udało?
4. F10 ustawienia: przejrzyj sekcje (nowa: „Replika (dysk wymienny)” —
   zwłoka po włożeniu, min. 60 s; „Pojemność” — bezpiecznik).

## B. Nowa relacja: pve9 → pve10 (Ins na F3)

1. Kreator nowej relacji: źródło pve9 (.99), datasety `hdd/data` (z dziećmi
   vm1-3). Profil domyślny.
2. Czy kreator jasno mówi, co się stanie na pve9 (konto, uprawnienia),
   a co na pve10?
3. Po założeniu: F3 pokazuje relację; pierwszy transfer — od razu czy
   o :21? Czy GUI mówi, kiedy?
4. Po pierwszym transferze: wiek kopii, rozmiar, w szczegółach relacji.

## C. Modyfikacja (Enter na relacji w F3, potem e)

1. Dodaj dataset do tej relacji (`hdd/lab/srv-a`). Plan zmian przed
   zatwierdzeniem — czy jest zrozumiały?
2. Usuń dataset z relacji (np. `hdd/data/vm3`). Co GUI mówi o kopii, która
   już jest na pve10?
3. Zmień harmonogram / profil retencji. Czy widać różnicę przed i po?

## D. Pauza i wznowienie

1. Wstrzymaj nową relację (F8 Pauza na F3). Po :21 sprawdź w F4 Historia, że nic
   nie poszło, i że F3 pokazuje wstrzymanie.
2. Wznów (F8 Wznów). Następny transfer o :21 — przeszedł? F7 Uruchom teraz —
   transfer od razu.
3. To samo na `relacja-cb` (bez ryzyka — wstrzymanie niczego nie usuwa).

## E. Zmiana adresu hosta

1. Okno „Adres hosta” na relacji pve9: wpisz zły adres → co mówi GUI?
   Wróć do dobrego (.99). Czy relacja dalej działa?

## F. Eksport → usuń → import

1. Eksport nowej relacji do pliku (F9 Eksport/Import na F3). Gdzie ląduje plik, czy GUI to mówi?
2. Usuń relację (Del). Plan usuwania: co zostaje (kopie na pve10?), co
   znika (konto na pve9, linie crona)? Czy jest jasne, że kopie danych
   zostają?
3. Import z pliku z punktu 1 (F9). Czy relacja wraca taka sama i czy kolejny
   transfer jest przyrostowy (nie od zera)?

## G. Druga maszyna dla tego samego źródła (synchro z inną maszyną)

1. Druga relacja: pve9 → **pve11** (kolektor .96), te same `hdd/data`.
   Czy GUI na pve11 pokazuje ją obok `relacja-bc`?
2. Lustro / kierunek odwrotny: na wzór `relacja-bc` (pve10 → pve11). Czy
   z GUI da się zrozumieć, który host jest źródłem, a który kopią?

## H. Replika na dysk wymienny (na pve9: `zfs-backup gui` na .99)

1. F6: replika `usb1` — stan, ostatnio widziany dysk.
2. Nowa replika na drugi dysk (`sdd`): przygotowanie nośnika, dataset
   `hdd/lab`, uruchamianie **po włożeniu**.
3. Na twoje hasło „wkładam”: podpinam dysk. Replika ma ruszyć dopiero po
   minucie (U52). Drugie hasło „oj, nie ten kabel”: podpinam i od razu
   odpinam — w dzienniku ma być „zniknął … nic nie robię”, bez importu.
4. Uruchom replikę ręcznie (F7 Uruchom teraz na F6). Zmień ją (harmonogram), usuń ją.

## I. Odzysk i przeglądanie kopii

1. F11 odzysk: z kopii `relacja-ab` (`hdd/data/docs`) — obok, nie w miejsce.
   Czy GUI mówi, gdzie ląduje kopia?
2. Przeglądaj kopię (F7 na F11 Odzysk) na `hdd/labbrowse/v-ntfs` i `v-luks` (klucz
   LUKS podam osobno). Skopiuj plik w `mc`, wyjdź F10. Komunikat
   „Odmontowane” na końcu.
3. Dwa okna PuTTY naraz, oba przeglądają ten sam dysk VM — oba mają działać,
   a po wyjściu obu `snapdev` wraca (świeże poprawki REV-160/161/162).

## J. Wygląd — na koniec, całościowo

- spójność nazw (relacja / kopia / replika / lustro) w całym GUI;
- angielskie wtręty w oknach (znane: U27/U31 — plany i błędy czasowników);
- klawisze tylko na ramce, nie w treści okien;
- czy coś wymaga dokumentacji, żeby zrozumieć.

## Po kampanii

Wyślij listę G1… (może być w kilku wiadomościach). Spiszę je do backlogu,
pogrupuję w paczki, zrobię, a potem jedno zbiorcze przejście recenzenta
i zamknięcie 1.0.
