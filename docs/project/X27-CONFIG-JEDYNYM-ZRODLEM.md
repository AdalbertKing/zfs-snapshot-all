# X27 — config jedynym źródłem prawdy, bez kopii szablonów w configu

Projekt do akceptacji właściciela, 2026-10-14. **Nic z tego nie jest zakodowane.**

## Założenie właściciela (2026-10-14)

> Mamy szablony, własne i fabryczne — one są tylko wzorcem do stworzenia relacji, czyli
> configa. Z szablonów powstają configi — jedyne źródło prawdy. To w nich można zmieniać
> relację poprzez GUI i poprzez ręczną edycję, lub wsadowo czasownikami. Zapis zmiany —
> zmienia relację. Proste i skuteczne. Pośrednicy to proszenie się o kłopoty.

Dodatkowo: relację można zapisać do pliku (eksport) i można z niej zrobić szablon.

## Co jest dziś nie tak

Relacja nie trzyma swoich liczb u siebie. Jej sekcje w configu tylko **wskazują** na bloki
`[template:...]` — kopie szablonu wklejone do configu:

```
[template:profile__relacja-lokalna-hdd-vms__hourly]     <- kopia szablonu
	send_schedule  = 1 * * * *
	retain         = -h24
	...
[dataset:hdd/ct]                                        <- relacja: źródło
	use_template = profile__relacja-lokalna-hdd-vms__hourly,...
[prune:hdd/backups/hdd/ct]                              <- relacja: cel
	use_template = profile__relacja-lokalna-hdd-vms__hourly,...
```

Z tego biorą się wszystkie dzisiejsze kłopoty:

| kłopot | skąd |
|---|---|
| T6: odmowa „already exists with different policy” | dwie relacje dzieliły jedną kopię szablonu |
| T6 krok 2: „could not take '' over” | źródło i cel dzieliły jedną kopię |
| F7 „Usuń nieużywane kopie szablonów” | kopie zostają po zmianie szablonu (pve9b: 33) |
| podział `lsrc_`/`src_`, „własna kopia” w set-tiers | kopię trzeba rozdzielić, zanim się ją zmieni |
| ręczna edycja: zmieniasz blok `[template:]` i nie wiesz, które relacje go czytają | wskazanie zamiast wartości |

## Co proponuję

**Relacja ma w configu jeden własny blok `[relation:NAZWA]` z wszystkimi swoimi liczbami.**
Sekcje źródła i celu mówią tylko „należę do relacji NAZWA”. Bloków `[template:]` pakiet
już nie pisze.

Ta sama relacja z pve9b po zmianie:

```
[relation:lokalna-hdd-vms]
	# powstała z szablonu d30h24-age, 2026-10-14
	tiers = hourly, daily
	hourly.send_schedule  = 1 * * * *          # kiedy migawka
	hourly.prefix         = automated_hourly_
	hourly.prune_schedule = 21 * * * *         # kiedy sprzątanie
	hourly.target_retain  = -h24               # ile trzyma CEL
	hourly.source_retain  = -h12               # ile trzyma ŹRÓDŁO
	hourly.monitor        = 90m 150m           # ostrzeż / alarm, gdy najnowsza starsza
	daily.send_schedule   = 11 1 * * *
	daily.prefix          = automated_daily_
	daily.prune_schedule  = 31 1 * * *
	daily.target_retain   = -d30
	daily.source_retain   = -d30
	daily.quiesce         = auto,degrade
	daily.monitor         = 30h 48h

[dataset:hdd/ct]
	relation  = lokalna-hdd-vms
	dst       = hdd/backups
	recursive = flat
	...
[prune:hdd/backups/hdd/ct]
	relation  = lokalna-hdd-vms
	recursive = yes
```

Zasady:

1. **Jedna relacja = jeden blok `[relation:]`**, nikt inny go nie czyta (generator odmawia,
   gdy sekcja innej relacji go wskazuje). Źródło i cel mają osobne liczby wprost
   (`target_retain`, `source_retain`) — nic do rozdzielania.
2. **Szablon (F5) to tylko wzór.** Nowa relacja i „Użyj szablonu” **przepisują** liczby
   szablonu do bloku relacji. Potem szablon nie ma z relacją nic wspólnego.
3. **Zmiana = zapis bloku.** GUI, ręczna edycja i czasowniki (set-tiers, edit-relation)
   zmieniają ten sam blok; każda zmiana to jedna podmiana configu po sprawdzeniu całości
   przez gen-cron (bez zmian — tak jak dziś).
4. **„Użyj szablonu” jednym zapisem**: liczby szablonu i liczby źródła z okna źródła
   trafiają do bloku w jednej podmianie (dzisiejsze dwa kroki znikają).
5. **Relacja → szablon** („Zapisz ustawienia relacji jako szablon”): blok `[relation:]`
   przepisany do pliku szablonu. **Relacja → plik** (eksport F8): blok `[relation:]` +
   jej sekcje — plik kompletny, bez odwołań do czegokolwiek spoza niego.
6. **Usunięcie relacji usuwa jej blok** razem z sekcjami. Nic nie zostaje.

## Co znika

- F7 „Usuń nieużywane kopie szablonów” (nie będzie czego sprzątać; dla starych configów
  zostaje czasownik `clean-templates`),
- rozdzielanie kopii `lsrc_`/`src_` w set-tiers, „własna kopia szablonu”, nazwy
  `profile__relacja-...`,
- strażnik kolizji szablonów przy zmianie relacji (nie ma czego dzielić),
- ostrzeżenie X6 „config zmieniany ręcznie” przy „Użyj szablonu” traci sens połowicznie:
  ręczna zmiana bloku JEST zmianą relacji; GUI czyta blok, więc widzi ją od razu.

## Czego to NIE rusza

- **Silników** (snapsend, snapget, delsnaps, check-snap-age, lib) — cron dostaje te same
  komendy co dziś. Zmienia się tylko opis zadania w cronie i w dzienniku
  (`profile__relacja-X__hourly` → `relacja X hourly`); podsumowanie dzienne
  (`hostscripts/alert-digest.sh`) dostanie nowy wzór obcinania nazwy.
- **Configów pisanych ręcznie** na produkcji (`jobs.<host>.conf` bez rekordów relacji):
  gen-cron dalej czyta `[template:]` + `use_template`, bez zmian. Pakiet tylko przestaje
  takie bloki PISAĆ. Produkcja przechodzi na nowy zapis dopiero przy przejęciu przez
  relacje (osobny temat).
- **Plików szablonów** (`profiles/*.conf`, własne na F5) — format bez zmian.

## Przejście istniejących relacji (lab: pve9b, pve10, pve11)

Czasownik `migrate-config` (plan + „tak”), dla każdego configu z relacjami:

1. z obecnych bloków `[template:]` i nadpisań w sekcjach składa blok `[relation:]` każdej
   relacji,
2. sekcje dostają `relation = NAZWA` zamiast `use_template`,
3. usuwa bloki `[template:]`, których nic już nie używa,
4. **dowód**: crontab po zmianie ma te same godziny i te same komendy co przed (różnić się
   może tylko opis zadania) — inaczej odmowa i nic nie zmienione.

## Etapy (każdy osobny PR, test na labie, zgoda przed następnym)

| etap | co | dowód |
|---|---|---|
| A | gen-cron czyta `[relation:]` (obok starego zapisu) | testy generatora: ten sam cron z obu zapisów; odmowa przy cudzym wskazaniu |
| B | tworzenie i zmiany piszą `[relation:]`: nowa relacja, „Użyj szablonu” (jeden zapis), set-tiers/show-tiers, add/remove-source, usuwanie relacji | testy czasowników + plan na labie |
| C | relacja → szablon, eksport/import relacji, GUI (F3, „Harmonogram i retencja”) czyta blok | testy tui + test właściciela |
| D | `migrate-config` + przejście pve9b, pve10, pve11 | crontab przed/po na żywo |
| E | sprzątanie: znikają F7, podział kopii, nazwy `profile__relacja-`; dokumentacja (README, JAK-TO-DZIAŁA) | testy, `impact --verify` |

Szacunek: duża zmiana — około 15 funkcji zapisujących w `zfs-backup.sh`, generator,
6 plików GUI, ~700 miejsc w testach (większość zostaje, bo stary zapis dalej działa).
Kilka rund pracy.

## Do decyzji właściciela

1. **Kształt bloku** `[relation:NAZWA]` jak w przykładzie wyżej (liczby szczebli z kropką:
   `hourly.target_retain`) — zgoda czy inaczej?
2. **Stary zapis zostaje czytany** (produkcja, configi pisane ręcznie), pakiet pisze tylko
   nowy — zgoda?
3. **Kolejność etapów A–E** jak w tabeli — zgoda?

## Zmiana planu (właściciel, 2026-10-14): bez zgodności wstecz

> Wywalmy więc tę zgodność. Pakiet wciąż jest w laboratorium. (...) Zredukujmy tę choinkę do
> minimum. Potem host po hoście przepiszesz configi i resztę do nowego standardu.

Zmierzone przed decyzją: produkcja (pve1-metro, pve2-metro) ma blok crona wygenerowany kiedyś z
`jobs.*.v4.conf`; samoaktualizacja (`deploy.sh`) crona NIE regeneruje, więc kopie chodzą dalej.
Nowym generatorem tych configów już się nie wyrenderuje — produkcja przechodzi na relacje przez
wyczyszczenie i założenie od nowa (decyzja 2026-10-08).

Każda sekcja relacji mówi, którą stroną jest: `side = target` (kopie) / `side = source`
(oryginały). Zgadywanie z kształtu sekcji było błędne (relacja lokalna: sprzątanie źródła to
`[prune:<źródło>]` bez `@`).

| krok | co |
|---|---|
| S1 | generator: `side` wprost (zrobione) |
| S2 | czasowniki wprost na bloku: tworzenie, „Użyj szablonu” jednym zapisem, set-tiers/show-tiers, źródła, usuwanie, relacja → szablon, eksport, czytelnicy |
| S3 | `migrate-config` (strony z rekordu relacji) + lab host po hoście: plan, „tak”, ten sam crontab |
| S4 | generator bez `[template:]`/`use_template` z pliku; kasacja: rozkładanie/składanie, własne kopie i podział `lsrc_`/`src_`, przemianowanie sekcji, strażnik kolizji, `clean-templates`/F7; testy na bloki |
| S5 | dokumentacja |
