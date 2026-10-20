# Lab klastrowy na Metropolis -- plan do zgody (2026-10-16)

Cel: zmierzyć pułapki projektu „jeden kolektor + pvesr” (`DESIGN-JEDEN-KOLEKTOR-PVESR-2026-10-16.md`) na prawdziwym
klastrze, **tylko na testowym gościu**. Prawdziwych gości (100, 101, 102, 103, 106, 107) ani maszyn labowych na pve2
(109–112: pve9, pve9b, pve10, pve11) nie ruszamy.

Rozpoznanie 2026-10-16, tylko odczyt:
- klaster `cluster`, 2 węzły, kworum OK;
- pula `hdd`: pve1 ma 5,3 TB wolnego, pve2 4,0 TB;
- magazyn `hdd-d0-vm-disks` na obu węzłach, szablon `debian-12-standard` na obu;
- replikacje produkcyjne idą pve1→pve2 co 3 h; 103 (pve2→pve1) jest wyłączona;
- między pve1 a pve2 nie ma parowania pakietu.

Każdy krok oznaczony **[ZMIANA]** wykonuję dopiero po twoim „tak” na ten krok. Kroki **[ODCZYT]** robię bez pytania.

## Etap 1 -- testowy gość i jego replikacja

1. **[ZMIANA] pve1:** kontener testowy **CT 990** `zfslab-pvesr`:
   - debian-12, nieuprzywilejowany, 1 CPU, 256 MB RAM;
   - dysk 2 GB na `hdd-d0-vm-disks`;
   - **bez sieci** (żadnego mostka), autostart wyłączony.

   Dataset: `hdd/vm-disks/subvol-990-disk-0`.
2. **[ZMIANA] pve1:** replikacja Proxmoxa **990-0** pve1→pve2 **co 15 min**. Czas skrócony, żeby pomiary nie trwały
   dniami; produkcja ma 3 h.
3. **[ODCZYT]** pierwsza synchronizacja przeszła: na pve2 jest replika `hdd/vm-disks/subvol-990-disk-0`.

## Etap 2 -- pułapki na tym, co już jest (bez nowego kodu)

Migawki na A robię tymczasowo ręczną linią crona na **pve1**, tylko dla `subvol-990`, w tym samym kształcie co
produkcja: `snapsend -m automated_hourly_ …` co 15 min plus prune. Kopię na B robię ręczną linią na **pve2**:
`snapsend -m automated_ -e … hdd/backups/lab-pvesr`, jak dziś dla 107.

4. **[ZMIANA]** dwie linie crona powyżej, oznaczone `# ZSA-LAB-PVESR`, żeby łatwo je usunąć.
5. **[ODCZYT] Blokady:** kilka cykli, w tym kopia na B ustawiona w tym samym czasie co synchronizacja. Mierzę, czy
   `pvesr` kiedykolwiek pada na blokadzie (`FailCount` dla 990-0) i czy blokady wyciekają.
6. **[ODCZYT] Opóźnienie:** po ilu minutach migawka z A pojawia się w kopii na B.
7. **[ODCZYT] Przycinanie:** prune na A znika na replice B przy następnej synchronizacji (`recv -F`) i nie psuje kopii
   w `hdd/backups`.
8. **[ZMIANA] Przełączenie gościa:** migracja CT 990 na pve2 (kontener zatrzymany, migracja offline).
   - Mierzę, co robi replikacja (odwraca się?) i co robią nasze linie na A i B.
   - Na koniec migracja z powrotem na pve1.
9. **[ODCZYT] Bramka:** czy bramka pary wpuszcza samo `zfs snapshot` (droga do „kopia: nigdzie” bez zmiany silnika).
   Dopiero po kroku 10, bo wymaga parowania.

## Etap 3 -- parowanie pod jeden kolektor

10. **[ZMIANA]** parowanie pakietu **pve2 (kolektor) ↔ pve1**, zakres **tylko `hdd/vm-disks/subvol-990-disk-0`**:
    - na pve1 powstaje konto delegowane kolektora, klucz z bramką i delegacja wyłącznie na ten dataset;
    - prawdziwe konto `zfsbackup` na pve1 i jego zadania zostają nietknięte.

    To pierwsza zmiana w zaufaniu między węzłami produkcji, więc osobna zgoda.

Dalsze kroki (relacja „kopia: nigdzie”, `local-backup --passive`, odmowa prune na replice) wymagają kodu. Po etapie 2
wrócę z pomiarami i z decyzją, co piszemy.

## Etap 4 -- REV-20261017-152 F5: relacja `snaponly` przy prawdziwej migracji (plan do zgody, 2026-10-17)

Czego chce recenzent (F5): prawdziwa migracja z zamierzonymi harmonogramami monitora i `pvesr`, obserwacja alarmu i
zmierzone okno czasowe -- łącznie z przypadkiem, w którym monitor trafia na świeżą migawkę na starym węźle, zanim
`pvesr` ją skasuje (bez obietnicy, że każdy układ czasów wykryje migrację). Alarmy przy braku migawek i przy awarii
bramki zrobione w labie pve9 -> pve10 (dziennik niżej); tu zostaje sama migracja.

Gość jak w etapach 1–3: tylko **CT 990** `zfslab-pvesr` (bez sieci, replikacja 990-0 pve1->pve2 co 15 min).

11. **[ODCZYT]** wersja pakietu na pve1 i pve2 (oba checkouty: root i `zfsbackup`) = obecny `main`; stan 990-0;
    crontab konta `zfsbackup` na pve2 -- kopia `/root/zfsbackup-crontab.before-f5-20261017`.
12. **[ZMIANA] pve2 <-> pve1:** relacja `snaponly` **na kolektorze pve2**, źródło `pve1:hdd/vm-disks/subvol-990-disk-0`:
    `zfs-backup.sh --source=192.168.28.9:hdd/vm-disks/subvol-990-disk-0 --mode=snaponly --name=lab990
    --local-user=zfsbackup --profile=d7h24 --install`. Na pve1 powstaje konto `zfsbackup-pve2` z bramką i delegacją
    **tylko na ten dataset** (zgoda zakresu na pve1). Prawdziwe konto `zfsbackup` na pve1 i jego zadania -- nietknięte.
    To pierwsze parowanie pakietu między węzłami produkcji (był w planie jako krok 10).
13. **[ODCZYT] przed aktywacją:** `activate-client lab990 --plan` -- pokazuję ci pełny diff crontaba pve2 (konto
    `zfsbackup`). Oczekiwane: dochodzi 6 linii `lab990` (2 migawki, 2 przycinania na pve1, 2 monitory), reszta bez
    zmian. Każda inna różnica = stop, wracam z nią.
14. **[ZMIANA]** `activate-client lab990 --yes` (jeśli diff z 13 jest czysty). Minuty migawek poza wielokrotnościami 5,
    `pvesr` 990-0 chodzi `*/15`.
15. **[ODCZYT]** 2–3 cykle: migawki `pve2_automated_hourly_*` na pve1, monitory OK, `pvesr` 990-0 FailCount 0,
    linie `# ZSA-LAB-PVESR` dalej działają (osobna rodzina `zsalab_`).
16. **[ZMIANA] migracja:** `pct migrate 990 pve2` (zatrzymany CT). Replikacja odwraca się sama (zmierzone 10-16).
    Mierzę co 5 min przez **~3 h** (próg ostrzeżenia szczebla godzinowego 90 min, krytyczny 150 min, monitor co
    15 min):
    - kiedy nasza migawka na pve1 (teraz celu replikacji) powstaje i kiedy `recv -F` ją kasuje;
    - co widzi monitor w każdym ticku (świeża migawka przed skasowaniem = OK -- przypadek z F5);
    - kiedy pierwszy WARNING i CRITICAL trafiają do kolejki alarmów pve2 i do maila.
    **Uwaga: to jest prawdziwy alarm z pve2 do ciebie** (tryb alarmów pve2 sprawdzę w kroku 11; przy `daily` przyjdzie
    w podsumowaniu, przy `immediate` od razu).
17. **[ZMIANA] powrót:** `pct migrate 990 pve1`; replikacja wraca; po następnej migawce monitor znów OK.
18. **[ZMIANA] sprzątanie etapu 4:** `delete-relation lab990` na pve2 (crontab pve2 porównany z kopią z kroku 11 co
    do linii), `deploy.sh --leave=pve2` na pve1 (konto `zfsbackup-pve2` i jego delegacja znikają). Migawki
    `pve2_*` na `subvol-990` usuwam ręcznie (to dataset testowy).

Ryzyka etapu 4:
- **crontab produkcyjnego konta `zfsbackup` na pve2:** aktywacja instaluje cały zarządzany blok z configu pve2.
  Dlatego krok 13 (diff) przed 14; po 18 porównanie z kopią.
- **obciążenie i `pvesr`:** migawka CT 990 to kilobajty; minuty poza `*/15`. Zderzenie z 18:30 (10-16) było przy
  tych samych minutach -- tu ich nie ma.
- **alarm do ciebie** w kroku 16 -- zamierzony, to jest dowód.

## Sprzątanie (na koniec albo przy dowolnym problemie)

- usunąć linie `# ZSA-LAB-PVESR` z crona pve1 i pve2;
- usunąć replikację 990-0, potem CT 990 (`pct destroy 990 --purge`), potem replikę na pve2 i `hdd/backups/lab-pvesr`;
- rozparować (`deploy.sh --leave`), jeśli był krok 10.

## Ryzyka i jak je trzymam w ryzach

- **Obciążenie pve2** (na nim działają maszyny labowe): dysk 2 GB, przyrosty kilobajtowe. Pomijalne.
- **Kolizja z produkcyjną replikacją:** osobne zadanie 990-0, inne datasety; produkcyjnych zadań nie dotykam.
- **Migracja (krok 8)** dotyczy tylko CT 990, zatrzymanego, bez sieci.
- **Cron produkcyjnego konta:** dopisuję tylko własne, oznaczone linie i tylko je usuwam (zasada „cron roota = moje
  linie”).

## Dziennik wykonania

- 2026-10-16 ~11:45 UTC -- **etap 1 zrobiony** (zgoda właściciela): CT 990 `zfslab-pvesr` na pve1 (debian-12, bez sieci,
  onboot 0, `hdd/vm-disks/subvol-990-disk-0` 299 MB); replikacja 990-0 pve1->pve2 `*/15`, pierwsza synchronizacja
  OK (FailCount 0), replika na pve2 jest.
- 2026-10-16 ~11:55 UTC -- **krok 4 zrobiony** (zgoda): linie `# ZSA-LAB-PVESR` w crontabie konta `zfsbackup`
  (kopie przed zmianą: `/root/zfsbackup-crontab.before-lab-pvesr-20261016` na obu węzłach). Prefiks `zsalab_`
  (poza wzorcem `automated_` produkcyjnego przycinania `hdd/backups`). Dzienniki: `/home/zfsbackup/lab-pvesr.log`.
  Zbieranie stanu co 5 min przez ~95 min (sesja), kroki 5–7.
- 2026-10-16 13:30–15:00 CEST (hosty Metropolis są w CEST) -- **kroki 5–7 zmierzone** (19 zrzutów co 5 min):
  - blokady: **brak**; `pvesr` 990-0 FailCount 0 / OK w 19/19 zrzutach, mimo kopii na B o tych samych minutach co
    synchronizacja. Silnik już omija blokadę na datasecie replikowanym przez Proxmox
    („Not holding … replicated by Proxmox VE (pvesr)”) -- pułapka 2 z projektu jest zamknięta w kodzie;
  - opóźnienie: kopia na B o :00 bierze migawkę z :45 (pvesr startuje sekundę po kopii) = jeden cykl `pvesr`;
  - przycinanie: prune na A znika na replice B przy następnej synchronizacji; kopia `hdd/backups/lab-pvesr` trzyma
    swoje (prefiks `zsalab_` poza produkcyjnym przycinaniem `automated_`);
  - błędy w dziennikach: brak.
- 2026-10-16 15:04 CEST -- **krok 8, migracja** (zgoda): `pct migrate 990 pve2` (zatrzymany CT) -- 5 s, rc 0.
  Replikacja 990-0 **odwróciła się sama**: source pve2, target pve1. Obserwacja trzech cykli (do ~15:50).
- 2026-10-16 15:05–15:55 CEST -- **gość na pve2 (replikacja odwrócona)**, 4 synchronizacje pve2->pve1, FailCount 0:
  - nasza linia na pve1 (teraz CEL replikacji) zrobiła migawki 15:15:01, 15:30:01, 15:45:01 -- dziennik
    „Successfully created” -- a synchronizacja sekundę później (`recv -F` strumienia `-R`) je **skasowała**: na nowym
    źródle ich nie ma. Fałszywe zdrowie: praca bez skutku, dziennik mówi sukces;
  - przycinanie na pve1 kasowało migawki na celu replikacji (tym razem bez błędu `pvesr`);
  - **wniosek:** wymóg właściciela „gość przeszedł -> relacja stop + alarm” jest konieczny; przy okazji zmierzone,
    że `recv -F` replikacji kasuje na celu nasze migawki (punkt 1 dyskusji „migawki tylko na B”).
- 2026-10-16 15:56 CEST -- `pct migrate 990 pve1`: 7 s, replikacja wróciła do pve1->pve2 sama, FailCount 0.
- 2026-10-16 18:30 CEST -- **pierwsza porażka `pvesr` 990-0** (alert do właściciela, FailCount 1): `command 'zfs snapshot
  hdd/vm-disks/subvol-990-disk-0@__replicate_990-0_1792168202__' failed: got timeout`. Przyczyna: nasza linia
  `snapsend.sh -m zsalab_` (`*/15`) i `pvesr` (`*/15`) zrobiły `zfs snapshot` tego samego datasetu w tej samej
  sekundzie (18:30:01); pula obciążona po replikacjach z 18:00 (load 6.5), więc nasza migawka trwała 11 s
  (18:30:01 -> 18:30:12) i `pvesr` przekroczył swój limit (18:30:15). Samo wróciło o 18:35 (FailCount 0);
  produkcyjne zadania 101/102/106/107 bez zmian. Wcześniejsze 19 cykli w tych samych minutach przeszło, bo pula
  była wolna.
  - **wniosek dla generatora:** linia samych migawek obok `pvesr` musi stać w minutach, w których `pvesr` nie
    rusza; silnik (`snapget -s`, REV-20261016-148) tego nie wymusi.
- 2026-10-16 19:29 CEST -- **[ZMIANA] (zgoda właściciela)** linia `# ZSA-LAB-PVESR` snapsend na **pve1** przesunięta
  z `*/15` na `2,17,32,47`; tylko ta jedna linia (diff 1 linia, crontab 28 linii przed i po). Kopia przed zmianą:
  `/root/zfsbackup-crontab.before-minute-shift-20261016` na pve1. Pierwszy bieg 19:32 -- migawka w 1 s; `pvesr`
  990-0 o 19:30 OK, FailCount 0. Linie na **pve2 nie ruszane** (używane tylko, gdy gość jest na pve2).
- 2026-10-17 -- **etap 4 (F5), zgoda właściciela na kroki 11–18.** Pakiet na pve1 i pve2: `main` `963d7baf`
  (godzinny self-update o 20:15 CEST); kopie crontabów root i `zfsbackup` na obu: `/root/*-crontab.before-f5-20261017`.
  - 20:13 -- `add-client lab990 --snaponly` na pve2 (osobne czasowniki, nie fasada z `--yes`, żeby diff był przed
    aktywacją); `--join` na pve1 ręcznie, zgoda zakresu: 1 dataset `hdd/vm-disks/subvol-990-disk-0`; konto
    `zfsbackup-pve2` z prawami tylko na nim.
  - 20:16 -- `activate-client --plan`: dochodzi dokładnie 6 linii (migawki :28 i 1:38, przycinanie :08 i 1:18, dwa
    monitory `*/15`), nic nie znika; `--yes` rc 0. Pierwsza migawka dzienna awaryjna (rc 8: konto nie ma prawa
    zamrażać gości) -- poprawny alarm w kolejce pve2.
  - 20:28, 20:30, 20:45 -- migawka `pve2_automated_hourly_…` na pve1, monitor OK, `pvesr` 990-0 FailCount 0, linie
    `# ZSA-LAB-PVESR` (`zsalab_`) bez zmian.
  - 20:47 -- `pct migrate 990 pve2` (5 s, rc 0); replikacja odwróciła się sama: pve2 -> pve1.
  - 21:28 i 22:28 -- nasza migawka na pve1 (teraz CEL replikacji): zadanie rc 0, „created”; o 21:30 / 22:30
    synchronizacja `recv -F` ją kasuje. Najnowsza widoczna zostaje `…20-28-01` (jest na obu węzłach, więc przetrwała).
  - monitor co 15 min: OK do 21:53 (85 min), **WARNING od 21:58 (90 min)** -- do kolejki alarmów pve2 o 22:00,
    22:15, …; **CRITICAL o 23:00** (`hourly stale`, 150 min). Alarmy przyjdą w dziennym podsumowaniu pve2 (tryb
    `daily`) na adres właściciela.
  - przypadek z F5 (monitor trafia na świeżą migawkę na starym węźle, zanim `pvesr` ją skasuje): przy tym
    rozkładzie NIE wystąpił -- migawka żyła ~2 min (:28 -> :30), tick monitora o :30 zbiegał się z synchronizacją.
    Przy `pvesr` co 3 h (produkcja) migawka może przetrwać na starym węźle do 3 h, a monitor mówi wtedy OK.
    **Nie ma skończonej granicy opóźnienia alarmu** (poprawka po REV-20261017-152 F5.1, 2026-10-20): stary węzeł
    dalej robi migawki, więc świeża migawka może zastąpić skasowaną przed następnym odczytem monitora i ten
    układ może się powtarzać bez końca -- alarm może przyjść z przerwami albo wcale, zależnie od zbiegu czasów.
    Kontrprzykład recenzenta (migawki co godzinę o :01, monitor co 15 min, `pvesr` co 3 h o :00): każdy odczyt
    widzi wiek 14-59 min, poniżej progu 90 min -- `docs/internal/reviews/evidence/REV-20261017-152-timing.py`.
    Monitor mierzy wiek migawek; nie ustala, który węzeł jest aktywny. Zostaje kontrakt: źródło wybiera admin
    (bez wykrywania położenia gościa -- decyzja właściciela).
  - 23:01 -- `pct migrate 990 pve1` (6 s), replikacja wróciła pve1 -> pve2, FailCount 0.
  - sprzątanie: `delete-relation lab990` (rc 0, razem ze stroną źródła), konto `zfsbackup-pve2` usunięte, migawki
    `pve2_*` na `subvol-990` usunięte; crontaby root i `zfsbackup` na pve1 i pve2 identyczne z kopiami.
