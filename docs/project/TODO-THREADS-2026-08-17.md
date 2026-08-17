# Otwarte wątki — stan na wieczór 2026-08-17

Zapisane na polecenie właściciela („Wrócimy do tego koniecznie"). Jeden wiersz =
jeden wątek do podjęcia; kolejność wg wagi ustalonej w rozmowie.

## Kolejka robocza (potwierdzona)

1. **`profiles/tiered`** — transkrypcja produkcyjnych szablonów ręcznych do
   profilu (tiery `automated_hourly_/daily_/weekly_` z własnymi prefiksami,
   płaskie liczniki, monitory per tier, quiesce od daily wzwyż, hourly płaski).
   **Uzasadnienie właściciela — zachować:** nazwa tieru to czytelny dla
   człowieka kontrakt spójności (daily = quiesced = spójny punkt startu
   odzyskiwania); w płaskiej rodzinie `automated_`+GFS cenne snapshoty giną w
   tłumie. Ponieważ quiesce w pakiecie failuje zamknięcie, nazwa jest uczciwym
   świadkiem: `automated_daily_` istnieje ⟹ zamrożenie się powiodło (per
   config). ŻADNEGO specjalnego mechanizmu oznaczania koherencji — odrzucone
   wprost. Dowód na labie przed merge.
2. **Forma `--source=HOST:`** (końcowy dwukropek = host bez datasetu) —
   odroczony zakres: pair+join+draft z pełną inwentaryzacją jako PROPOZYCJA
   (z rozmiarami), operator wybiera, ponowienie z `--source=HOST:DS…` wchodzi
   znanym torem. Z natury dwukrokowa — `--grant-remotely` nie ma tu czego
   podpisać przed wyborem. Forma `--source=HOST: --mode=sync` = „zdublowany
   serwer backupu jedną komendą" (generalizacja pve9).
3. **vsql2: natywny backup SQL w gościu** — SQL Agent (usługi już są:
   `SQLSERVERAGENT`, `SQLAgent$SQL2019`) + `BACKUP DATABASE` w pętli albo
   skrypty Ola Hallengrena; pliki na dysk w `rpool/data`, dalej niesie je nasz
   łańcuch. Przed startem: pomiar łącznego rozmiaru baz (FULL co noc vs
   FULL+DIFF). Werdykt VSS (strukturalny: ~9 s freeze przy ~200 bazach vs
   limit ~10 s Windows) w `infra_vsql2_vss_sqlwriter` — `quiesce = no` na
   11.11 ma się stać DECYZJĄ (poprawić komentarz w configu), czeka na
   potwierdzenie właściciela.
4. **`clean_all`** — skrypt sprzątający pozostałości testowe; taksonomia
   śmieci + luki narzędzi (`--leave` nie sprząta `relationships/`,
   `remove-client` zostawia confy `STATE=removed`) spisane w pamięci
   projektu (project_clean_all_knowledge). Zasada: whitelist, nigdy sweep.

## Decyzje wiszące u właściciela

- **Restore / grant kliencki** — 5 pytań na końcu
  `docs/design/client-granted-restore.md` (pull-first?, granularność grantu,
  czas życia, sieroty `leave|destroy`, grant po nieudanej próbie). S0
  (kontrola miejsca) i S1 (plumbing grantu) mogą iść niezależnie.
- **Reinstalacja crontabów floty pod markery ZFS-JOB** — bloki na hostach są
  przed-markerowe; po PR #35 przejście jest bezpieczne (strażnik ślepy na
  markery), ale sama reinstalacja to decyzja per host.
- **VM 102 (neth): replikacja pvesr co tydzień** vs 3 h dla reszty — zamiar
  czy przeoczenie? (Snapshotowo maszyna już objęta backupem od 2026-08-01.)
- **Agent QEMU w neth (VM 102)** nie działa mimo `agent: 1` — podnieść przy
  okazji, wtedy maszyna odzyska quiesce.

## Tematy zaparkowane świadomie

- **Słownik profili `family`/`role`/`coherence`** — skreślony po dyskusji
  („zagmatwaliśmy"); obowiązuje model prosty: profil = prefix + kadencja +
  drabina + progi (+ kiedyś quiesce). Wrócić wyłącznie od jednej kartki.
- **Hooki w pakiecie** (`pre_snapshot_cmd`) — kolidują z granicą „config to
  dane, nie kod"; jedyny dopuszczalny kształt to wzorzec zfs-quiesce-helper
  (mechanizm w repo, wywołanie po nazwie). Dziś niepotrzebne: Linux ma
  `fsfreeze-hook`, Windows/SQL ma SQL Agenta.
- **F7-refaktor**: pasywność jako `profiles/mirror` zamiast inline-emisji —
  czysty adres tej samej polityki, bez zmiany zachowania.

## Laboratorium (stan)

- pve9 (VM 109 na pve2, 192.168.28.99) — zostaje jako stały drugi kolektor
  labu; strefa czasowa UTC celowo (eksponat F6).
- Łańcuch finałowy: ogniwo A na etapie aktywacji (za PR #35), ogniwo B do
  ponowienia po A; dane źródłowe `hdd/lab3/src/dane.bin` md5 `ab0c4933…`.
