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
