# Fastprune bez alertów -- krótkie życie migawek na źródle (U136, do GUI w 1.0)

Stan na: 2026-11-01. Nazwa trybu: właściciel („fastprune without alerts”).

## Po co

Migawki zdalne (snaponly) na źródle z małą pulą, gdy pełną historię trzyma ktoś inny:

```
źródło (mała pula)  --pvesr co 2 h-->  replika na kolektorze  --kopia pasywna-->  archiwum
   migawki wszystkich szczebli            to samo, co źródło         długa retencja
   żyją krótko (np. 48 h)
```

Archiwum ma mieć szczeble dobowe, tygodniowe, miesięczne i roczne, więc źródło musi je
TWORZYĆ. Ale na źródle każda z nich ma żyć tylko tyle, ile trzeba, żeby pvesr ją przeniósł,
a kopia pasywna skopiowała do archiwum.

Przypadek, na którym to wyszło: Site-B 2026-11-01, kolektor pve0, źródło pve1
(.11.11, jedna pula `rpool`). Tam miejsca okazało się dość i właściciel zrobił zwykłą
relację. Tryb ma być w GUI dla hostów, gdzie miejsca nie ma.

## Dlaczego dziś GUI tego nie zrobi

- Retencja szczebla w szablonie to LICZBA (`keep = 1` -> `-Y1`) albo WIEK w jednostce
  szczebla. Edytor szablonów (F5, `tui/template.sh:221`, `:224`) ma sposób „WIEK (age)”, ale
  roczny szczebel liczy wtedy w latach, miesięczny w miesiącach. Najmniej to 1
  (`tui/grid.py:290`; zero tylko w oknie zmiany retencji źródła, `zero_ok`). Roczna migawka żyje więc na źródle co najmniej rok i przez ten rok
  trzyma w puli wszystko, co się od niej zmieniło.
- Czyszczenie szczebla chodzi w terminie szczebla (`prune_schedule`, domyślnie wzięty z
  `send_schedule`, `zfs-backup.sh:12309`): roczne raz w roku, miesięczne raz w miesiącu.
  Nawet `retain = -h48` na rocznym szczeblu zadziałałoby dopiero przy następnym biegu, za rok.
- Monitor szczebla na źródle (`check-snap-age` przez SSH) pilnuje wieku najnowszej migawki.
  Po 48 h tygodniowej na źródle już nie ma, więc monitor zgłosi CRITICAL, choć wszystko
  działa. Stąd „bez alertów”: wiek tych szczebli pilnuje monitor archiwum, nie źródła.
- Strażnik pojemności na źródle NIE pomoże: zmierzone na pve1 (`capacity-guard.sh --plan`):
  „NIC nie usunie: brak configu /etc/zfs-snapshot-all/jobs.pve1.conf ani jobs.pve1.<konto>.conf”. Linie czyszczenia
  migawek zdalnych leżą na kolektorze, a linia zdalna (`host:dataset`) nie daje strażnikowi
  prawa kasowania (`hostscripts/capacity-guard.sh:11-12`). Przy migawkach zdalnych jedyną ochroną
  puli źródła jest retencja relacji.

## Jak to zrobić dziś ręcznie (sprawdzone na kopii)

Edytuje się PROFIL relacji, nie `jobs.*.conf` -- config jest generowany z profilu
(`emit_snaponly_sections`, `zfs-backup.sh:12245`), więc ręczna zmiana configu zniknęłaby
przy pierwszej zmianie relacji.

Plik: `/etc/zfs-snapshot-all/profiles/<profil relacji>.conf` (kreator zapisuje własny,
ukryty profil `relacja-<nazwa>`). W KAŻDYM `[template:<szczebel>]`:

```
	prune_schedule = 21 * * * *      # co godzinę; minutę generator i tak przesuwa
	retain         = -h48            # wiek, nie liczba; zamiast keep = N
```

`keep` usunąć (`keep` i `retain` się wykluczają). W szczeblach, których wiek ma pilnować
archiwum (tygodniowy, miesięczny, roczny), usunąć OBA pola `monitor_warn` i `monitor_crit`:
generator migawek zdalnych pisze monitor szczebla tylko wtedy, gdy są oba
(`zfs-backup.sh:12295`); jedno pole bez drugiego `gen-cron.sh` odrzuca (`gen-cron.sh:2219`).
Potem przegenerować relację (polecenie do potwierdzenia przy pierwszym użyciu na żywo --
nie było sprawdzane).

Co sprawdzono 2026-11-01 na pve0 (kopia configu w `/tmp`, bez instalacji):

- `gen-cron.sh -c <kopia>` bez `--install`: rc=0, zero ostrzeżeń;
- wynik: 5 linii migawek bez zmian; 5 linii czyszczenia `4 * * * *`, każda
  `delsnaps.sh -R -L pve1 "zfsbackup-pve0@192.168.11.11:rpool/data" "pve0_automated_<szczebel>_" -h48`;
  monitory tylko godzinowy i dobowy;
- `delsnaps.sh -n … -h1` przez SSH z kluczem relacji: połączenie i próg wieku działają.
  Usunięcia nie było czego pokazać (żadna migawka nie była starsza niż godzina) --
  dowodu kasowania jeszcze brak;
- crontab konta i config produkcyjny bez zmian (md5 przed i po).

## Ryzyko, które tryb musi mówić wprost

pvesr usuwa z repliki to, co zniknęło ze źródła (zmierzone: replika `vm-100-disk-0` na
pve0 miała dokładnie 12 godzinowych, tyle, ile trzymało źródło przy `-h 12`). Jeśli kopia
pasywna nie skopiuje migawki, zanim minie czas życia na źródle, ta migawka przepada w
archiwum na zawsze. Czas życia = okno na awarię archiwum. 48 h wystarcza przy biegach
archiwum kilka razy na dobę; awaria przez weekend -- nie. Dlatego wartość ustawia admin.

## Do GUI w 1.0 -- propozycja

Kreator relacji, rodzaj „Migawki zdalne”, krok „Jak długo trzymać migawki na źródle?”
(`tui/new-relation.sh:697`) -- dodatkowa pozycja obok szablonów:

```
Szybkie czyszczenie źródła (fastprune)   wszystkie szczeble żyją [48] godz.
```

Wybór tej pozycji:

1. pyta o liczbę godzin (domyślnie 48, najmniej 4 -- dwa cykle pvesr po 2 h; ostrzeżenie
   poniżej 24);
2. zapisuje w profilu relacji: `retain = -h<N>` i czyszczenie co godzinę w każdym szczeblu,
   a monitory zostawia tylko szczeblom, których odstęp jest krótszy niż N (godzinowy
   zawsze; dobowy, gdy N > 24, z progiem ostrzeżenia poniżej N);
3. w podsumowaniu i oknie relacji pokazuje: „źródło: fastprune <N> h, bez monitorów
   szczebli wyższych -- ich wiek pilnuje archiwum”, oraz zdanie o ryzyku z sekcji wyżej;
4. okno relacji (zmiana) pozwala zmienić N i wyłączyć tryb -- te same pola.

Warunek uczciwości: tryb ma sens tylko wtedy, gdy archiwum istnieje. Kreator powinien
sprawdzić, czy na kolektorze jest kopia pasywna z repliki tych datasetów, a jeśli nie --
powiedzieć to przed „Utwórz”.

Do rozstrzygnięcia przy implementacji: jedna wartość N dla wszystkich szczebli czy osobna
dla godzinowych (np. 24 h godzinowe, 48 h reszta).
