# Zmiana relacji migawek zdalnych trwa minuty -- pierwsze migawki przy każdej zmianie (U137)

Stan na: 2026-11-01. Zgłoszenie właściciela: „Modyfikacja relacji dla user: zfsbackup trwa
ponad 2 minuty, dla roota trwała szybciej.”

## Przyczyna (zmierzona na pve0, Site-B)

Konto nie ma znaczenia. Czas zjadają PIERWSZE MIGAWKI KAŻDEGO SZCZEBLA, robione od nowa po
każdej zmianie relacji, jedna po drugiej, każda z zamrażaniem VM na źródle.

1. `edit-relation` instaluje przez tę samą ścieżkę co aktywacja i na końcu woła
   `snaponly_first_snapshots` (`zfs-backup.sh:12644`, `:12653`). Ta funkcja uruchamia
   linię migawki KAŻDEGO szczebla relacji po kolei, bez sprawdzenia, czy migawka tej
   rodziny już na źródle jest (`:12656-12690`).
2. Szczeble dobowy, tygodniowy, miesięczny i roczny mają `quiesce = auto,degrade`, więc każdy
   z nich zamraża VM na pve1 przez agenta gościa. Na pve1 zamrażanie VM 100 nie działa
   poprawnie: w każdym biegu linia z cron.log „Quiesce[192.168.11.11]: VM 100 is no longer frozen
   before the snapshot of pool rpool” (komunikat z `lib-zfs-snap.sh:2974`), bieg kończy się
   migawką `_crash_` (rc=8), a `qm guest cmd 100 fsfreeze-thaw` wisiał 53 s i dłużej.

Pomiary 2026-11-01 (`/home/zfsbackup/cron.log`, `/root/scripts/cron.log` na pve0):

| bieg | szczeble | pierwsze migawki | czas |
|---|---|---|---|
| relacja na root (20:38) | godzinowy, dobowy | 20:38:28 - 20:38:59 | 31 s |
| relacja na zfsbackup (20:50) | 5 szczebli | 20:50:26 - 20:53:44 | 3 min 18 s |
| zmiana relacji (21:04) | 5 szczebli, wszystkie migawki już były | od 21:04:25; tygodniowa 2 min 14 s, miesięczna trwała jeszcze o 21:08:50 | ponad 4 min |

Bez pierwszych migawek ta sama zmiana trwa sekundy: `edit-relation pve1 --plan` 2,9 s;
`edit-relation pve1 --yes` bez zmian 5,8 s -- jego pierwsze migawki odbiły się od blokady
trwającego biegu (rc=75), więc niczego nie zrobiły. `gen-cron.sh` na tym configu: root 0,63 s,
`zfsbackup` 0,67 s.

Root „trwał szybciej”, bo jego relacja miała 2 szczeble, a nie 5.

## Decyzja właściciela 2026-11-01: BŁĄD, priorytet do 1.0.6 -- wariant C

Słowa właściciela: „to błąd. Priorytetowo do naprawy 1.06 -- założenie relacji nie może
tworzyć wszystkich szczebli od razu, szczególnie freeze.”

~~Pierwsza wersja wymagań (najwyżej jedna migawka najdrobniejszego szczebla przy aktywacji)~~ --
zastąpiona tego samego wieczoru. Relacja migawek lokalnych `migawki-hdd-lxc-subvol-102` robi
dziś przy aktywacji właśnie tylko godzinową, i jej szczebel roczny od razu pokazał „stale”
(U144). Właściciel: „U137 -- niekoniecznie”; warianty „wszystkie szczeble bez zamrażania” i
„tylko najdrobniejszy” odrzucił („nie podobają mi się oba warianty”).

**Decyzja właściciela 2026-11-01: wariant C.**

1. **Założenie i zmiana relacji nie robią żadnej migawki** -- ani wszystkich szczebli, ani
   najdrobniejszego, żadnego zamrażania. Każdy szczebel dostaje pierwszą migawkę w swoim
   terminie z crona, jak każdą następną. Dotyczy migawek zdalnych (dawne `snaponly_first_snapshots`,
   usunięte w C1) i migawek lokalnych (dziś jedna godzinowa przy aktywacji -- zmierzone na pve0 11-01: `automated_hourly_2026-11-01_22-36-51` na obu dyskach `subvol-102`, „Seed: OK (2 source(s) sent)”).
2. **Monitor: „czeka na pierwszy termin”, nie „stale”.** Szczebel bez żadnej migawki swojej
   rodziny ma stan „czeka na pierwszy termin” z datą najbliższego biegu z crona (np. „roczne:
   czeka, pierwsza 2027-01-01 04:41”). „Stale” dopiero wtedy, gdy ten termin minął (liczony od aktywacji
   relacji, `ACTIVATED_AT`), a migawki dalej nie ma. Dziś wiek takiego szczebla jest liczony od
   utworzenia datasetu (`check-snap-age.sh:511`) -- to znika. Razem z U144 i U131.
3. **Panel relacji: każdy szczebel osobno** -- jego stan, termin i próg; bez sklejania wieku
   jednego szczebla z progiem innego (`tui/zfs-tui.py:2828-2835`, U144).
4. **Dowód:** założenie i zmiana relacji na labie -- w cron.log brak `ZFS-JOB BEGIN` między
   wykonaniem a pierwszym terminem z crona; monitor w tym czasie „czeka”, nie WARNING/CRITICAL;
   pierwszy bieg z crona robi migawkę i stan przechodzi w aktualny.

5. **Relacje z KOPIĄ (backup, kopia lokalna) -- także pierwsza pełna kopia czeka na swój termin
   z crona** (właściciel 2026-11-01: „czeka na termin”). Założenie relacji trwa sekundy; do
   pierwszego biegu kopii nie ma, a stan relacji mówi „czeka na pierwszy termin” z datą. Dziś
   pierwszą kopię wysyła aktywacja (`activate_first_copies`, `zfs-backup.sh:13254`).

## Pozostałe

1. **Zamrażanie VM 100 na pve1 -- osobno, na hoście.** Każdy szczebel z zamrażaniem daje
   migawkę `_crash_` i trwa od 27 s do ponad 2 min. Do sprawdzenia agent gościa w VM 100
   (wersja, `fsfreeze-status`, dziennik w gościu). Do decyzji właściciela, czy w tej relacji
   VM 100 ma być zamrażana; dopóki zamrażanie nie działa, kosztuje czas i nic nie daje.

## Drobne znaleziska z tego samego pomiaru

- Każde `edit-relation` dopisuje do configu pustą linię po `[defaults]` (diff w planie:
  `@@ -2,6 +2,7 @@` z jednym `+` pustym). Bez wpływu na crontab; do usunięcia.
- Plan zmiany relacji z GUI (zapis na pve0: `/root/.zfs-tui/edit-relation-20261101-210327-plan.txt`) pisze
  „template:snaponly__pve1__hourly, keeps (age): -W1 -> -W4” -- zmiana dotyczy szczebla
  tygodniowego i liczby, nie wieku. W ostrzeżeniu planu zła nazwa szczebla i „age” zamiast liczby.
