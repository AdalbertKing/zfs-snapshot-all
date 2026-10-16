# Jeden kolektor dla klastra z replikacją Proxmoxa (projekt do decyzji, 2026-10-16)

Status: **PROJEKT, nic nie kodowane.** Pomysł właściciela z 2026-10-16; ocena i warianty: sesja implementera.

## 1. Dziś (zmierzone na Metropolis, 2026-10-16, tylko odczyt)

| host | co robi nasz pakiet | skąd |
|---|---|---|
| **pve1** (A) | migawki gości: `snapsend -m automated_* "<lista>"` bez celu (tylko migawki) + przycinanie | crontab konta `zfsbackup` |
| replikacja Proxmoxa | `pvesr` A→B dla 101, 102, 106, 107 co 3 h (`zfs send -R` / `zfs recv -F`) | `pvesr status` na pve1 |
| **pve2** (B) | kopia replik do `hdd/backups/pve2`: `snapsend -m automated_ -e` (bez własnych migawek) + przycinanie `hdd/backups` + własne zadania dla swoich gości (root, 103) | crontab konta `zfsbackup` |

Minus: dwa miejsca zarządzania (A: migawki i prune; B: kopia i prune), dwa źródła maili. To, co się dzieje na A,
B widzi tylko pośrednio (przez replikę).

## 2. Propozycja właściciela: jeden kolektor = B

Na B dwie relacje:

1. **Relacja B↔A, „kopia: nigdzie”.** B robi migawki na A i je tam przycina, ale niczego nie przesyła. Dane jadą na B
   replikacją Proxmoxa, jak dziś.
2. **Relacja jednohostowa na B, pasywna.** Kopiuje repliki (datasety, które Proxmox odbiera na B) do
   `hdd/backups`, **bez własnych migawek**: bierze migawki, które przyszły z A.

Jedno miejsce zarządzania (GUI na B), jeden host wysyła maile.

## 3. Co z tego już mamy, a czego nie

| element | stan |
|---|---|
| kolektor robi migawkę na źródle zdalnym | jest -- ale tylko RAZEM z transferem: w relacji pobierającej `snapget -m <prefiks>` tworzy migawkę na źródle zdalnym przed pobraniem (`gen-cron.sh` ~614) |
| kolektor przycina źródło zdalne | jest -- zadania `src_* prune` (`delsnaps -L … -K klucz` przez bramkę) |
| strażnik wieku migawek na źródle zdalnym | jest -- dla relacji pobierającej |
| **migawka na źródle zdalnym BEZ przesyłania** | **nie ma.** `snapget.sh` ma tryb „tylko migawka” wyłącznie lokalnie (`src == tgt` i brak hosta). Zmiana w zamrożonym silniku -> recenzent. Alternatywa bez silnika: osobny mały krok (`zfs snapshot` przez bramkę) -- trzeba sprawdzić, czy bramka go wpuszcza |
| **kopia lokalna pasywna** (bez własnych migawek) | (dla porządku: lokalne „tylko migawki” to `local-backup --target=''`) **mechanizm jest** -- silnik `-e` i pole configu `passive = yes` (generator `add_scope_flags`), gramatyka nie ogranicza go do relacji zdalnych. **Brakuje tylko drzwi:** przełącznika w `local-backup` i opcji w kreatorze „Lokalnie”; dlatego produkcja ma ręczną linię `snapsend -e`. Do potwierdzenia planem na labie (relacja lokalna z `passive = yes`) |
| przełącznik w GUI („kopia: nigdzie”, „lokalnie pasywnie”) | nie ma |

## 4. Pułapki (znane z incydentów)

1. **B nie przycina replik.** Replika na B jest odbierana `zfs recv -F` z A, więc kasuje na B to, co znikło na A.
   Przycinanie wolno robić tylko na A (relacja 1) i w `hdd/backups` (relacja 2). Generator musi odmówić prune na
   datasecie, który jest celem `pvesr`.
2. **Blokady (`zfs hold`) na replice zatrzymują `pvesr`.** Incydent 2026-07-25, Nextcloud 107: wyciekłe blokady kopii
   na replice na pve2 -> `pvesr` padał 14 h. Wyciek naprawiony, ale kopia z repliki, która trzyma blokadę akurat w
   chwili synchronizacji, może przerwać jedną synchronizację. Do zmierzenia; ewentualnie kopia bez blokady albo
   okna: kopia na B tuż po synchronizacji `pvesr` (co 3 h), nie w trakcie.
3. **Kolejność w czasie.** Migawka na A o :00 trafia na B dopiero z najbliższą synchronizacją (do 3 h). Kopia na B
   widzi więc migawki z opóźnieniem; strażnik wieku na `hdd/backups` musi to uwzględniać (próg >= kadencja `pvesr`).
4. **Przełączenie gościa na B (HA, migracja).** Gość działa wtedy na B, replikacja odwraca kierunek. Relacja 1 dalej
   robi migawki na A, gdzie dysku już nie ma albo jest repliką. Trzeba ustalić zachowanie (odmowa + alarm? relacja
   idzie za gościem?). Dziś przy dwóch kolektorach ten problem też istnieje, tylko mniej widać.
5. **B leży.** Patrz ocena niżej: to najważniejsza różnica.

## 5. Ocena: jeden kolektor czy dwa

| kryterium | dwa kolektory (dziś) | jeden kolektor (propozycja) |
|---|---|---|
| zarządzanie | dwa GUI, dwie konfiguracje | **jedno miejsce** |
| maile | dwa źródła | **jedno** |
| migawki na A, gdy B leży | **robią się dalej** (cron na A) | **stają** -- tworzy je B przez SSH |
| alarm, gdy B leży | A dalej wysyła swoje | **nikt nie wysyła** (cisza) |
| nowy kod | zero | przełącznik relacji + generator + GUI + **zmiana silnika lub nowy krok** + `local-backup --passive` |
| spójność prune | dwie retencje do pilnowania ręcznie | jedna retencja w jednym miejscu |

**Wniosek implementera: dobry kierunek, z jednym świadomym kosztem.**

Zarządzanie w jednym miejscu to realny zysk. Retencja A i kopia B są dziś rozjechane w dwóch konfiguracjach i nikt
nie widzi ich razem. Koszt: gdy B leży, na A nie powstają nowe migawki, a alarmu brak, bo milczy jedyny nadawca.

W klastrze dwuwęzłowym awaria B to i tak stan awaryjny: brak repliki, brak HA. Ochrona na ten czas spada do ostatnich
migawek na A. Koszt da się zamknąć bez drugiego kolektora:

- **cisza = sygnał.** Codzienny mail podsumowania już jest („1 mail/dzień”). Brak maila do 8:00 to awaria.
  Najprościej sprawdza to człowiek; można też dodać strażnika „dead man's switch” poza B.
- opcjonalnie **zapasowe migawki na A**: pojedynczy wpis crona na A, który robi migawkę tylko wtedy, gdy B nie zrobił
  jej od N godzin. To jednak powrót części zarządzania na A, więc lepiej najpierw bez tego.

Jeśli brak migawek na A podczas awarii B jest nie do przyjęcia, to zostają dwa kolektory i nic nie piszemy.

## 6. Kolejność, jeśli kierunek przyjęty

1. **Lab klastrowy**: dwa węzły w klastrze Proxmoxa z `pvesr` (dziś lab to osobne hosty). Bez tego nie da się
   zmierzyć pułapek 1–4.
2. `local-backup --passive` (czasownik, generator, GUI „Lokalnie, bez własnych migawek”) -- **niezależne**, przyda
   się od razu: zastępuje ręczną linię `snapsend -e` na pve2.
3. „Kopia: nigdzie” w relacji zdalnej: najpierw sprawdzić, czy bramka wpuszcza `zfs snapshot` bez silnika; jeśli
   nie -- zgłoszenie do recenzenta (zmiana w `snapget.sh`).
4. Odmowa prune na datasecie-celu `pvesr` (generator).
5. Kampania na labie klastrowym (blokady, opóźnienie, przełączenie gościa, B wyłączony).
6. Migracja Metropolis: dopiero po labie, za zgodą właściciela.

## 7. Pytania do właściciela

1. Czy „B leży -> na A nie ma nowych migawek” jest do przyjęcia (z sygnałem „brak maila”)?
2. Przełączenie gościa na B: odmowa i alarm czy relacja ma iść za gościem?
3. Zgoda na lab klastrowy jako pierwszy krok?

## 8. Odpowiedzi właściciela (2026-10-16)

1. **B leży -> brak nowych migawek na A: do przyjęcia.** W nowym modelu na A nie ma żadnej linii crona pakietu
   (tylko konto i bramka; dzisiejsze linie migawek na A z §1 znikają). **Do przemyślenia:** awaryjna, zapauzowana relacja jednohostowa na A, która wstaje sama, gdy brak
   kontaktu z kolektorem dłużej niż N. Projektując, rozstrzygnąć powrót B (żeby obie strony nie robiły migawek naraz).
2. **Gość przeszedł na B -> relacja się zatrzymuje** (pomija bieg + alarm). Migawki na celu replikacji idącej w drugą
   stronę zakłócają klaster. Wykrywanie do ustalenia: węzeł, na którym Proxmox trzyma konfigurację gościa, albo kierunek
   `pvesr`.
3. **Lab klastrowy: zgoda, tylko dla datasetów labowych, na klastrze Metropolis (pve1/pve2)** -- testowy gość /
   testowe datasety obok produkcji; prawdziwych gości nie ruszamy. Hosty produkcyjne: plan krok po kroku i zgoda
   na każdy krok zmieniający hosty.
