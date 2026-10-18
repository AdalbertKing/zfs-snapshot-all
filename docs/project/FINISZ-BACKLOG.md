# FINISZ -- backlog paczek (od 2026-10-18, tydzień)

Tryb pracy (właściciel 2026-10-18): właściciel zgłasza uwagi w trakcie obserwacji,
implementer zapisuje je TUTAJ (numer, słowa właściciela) i łączy w paczki. Jedna paczka =
jedna gałąź = jeden PR, scalany po zielonym CI. Bez suit lokalnie (CI ~3 min). Na żywo na
pve9 tylko to, co widać w GUI. Recenzent i łatanie -- po paczkach.

Cel: każda funkcjonalność pakietu dostępna z GUI, z chudym odzyskiem.

## Paczki (kolejność)

| # | paczka | zawartość | stan |
|---|---|---|---|
| A | Cykl relacji w GUI | relacja nie-aktywna (1. kopia, czeka na źródło, zmiana adresu w toku): w oknie relacji jeden klawisz „dokończ” = następny krok (`seed` / `verify-endpoint` / `activate`), zamiast komendy do przepisania -- ZROBIONE (`d dokończ`, #609); wyłącz/włącz -- ZROBIONE (F8: `w` = Wyłącz z wyjaśnieniem i drogą powrotu; wyłączona: F8 Włącz) | zrobione |
| B | Chudy odzysk | F11 (#608); „Przeglądaj kopię” runda 1 -- ZROBIONE #611 (F7 na F11: migawka RO, `mc`, odmontowanie; datasety plikowe; właściciel skopiował plik z migawki, pve9 10-18); zvol (VM) „light” -- ZROBIONE (partycje NTFS/ext4/xfs/vfat/exfat/btrfs tylko do odczytu, LUKS i BitLocker po podaniu klucza; LVM/RAID -- nie); łańcuch C->A z pominięciem B -- NIE w 1.0 (właściciel 10-18: to odzysk z innego kolektora; jest odzysk z ręcznej kopii, odzysk z ręcznie podłączonego kolektora -- po 1.0) | w toku |
| C | Retencja | wada `[prune:]` gubi `gfs=yes` -- ZROBIONE #610 (drabina `-G` na szczebel po stronie źródła; lądowiska płaskie; migawki zdalne przyjmują GFS). Retencję źródła okno relacji już pokazuje; `audit-source-retention` to jednorazowa migracja hosta -- CLI | zrobione |
| D | Replika | `purge-replica-copy` -- USUNIĘTY z pakietu (właściciel 10-18: „nie chcemy tego”; dysk czyści formatowanie w „Dodaj dysk”); `remove-media-trigger` -- ZROBIONE w oknach (plan zmiany/usuwania repliki zdejmuje regułę, gdy żadna replika nie rusza po włożeniu) | zrobione |
| E | Suity | `test/tui` z selektorem sekcji; przegląd duplikatów w `zfsbackup`/`localbackup` (165 s i 143 s w CI); zmiana klawisza/ekranu nie ciągnie całego drzewa | do zrobienia |
| F | Uwagi z obserwacji | wpisy U1.. poniżej, zbierane do najbliższej paczki | otwarte |

Tylko CLI (świadomie, bez okna): `setup-server` (instalacja hosta), `move-to-client`,
`final-catchup`, `pause-writers`/`resume-writers` (deploy), `show-scope`, `test`, `help`,
`audit-source-retention` (migracja hosta).
Do decyzji właściciela, jeśli któreś ma mieć okno.

## Uwagi właściciela (U1..)

| # | data | słowa właściciela / co | paczka | stan |
|---|---|---|---|---|
| U1 | 2026-10-18 | „Wszedłem do migawki i skopiowałem plik do /mnt” -- Przeglądaj kopię działa na żywo | B | potwierdzone |
| U2 | 2026-10-18 | „purge-replica-copy -- nie chcemy tego. Można sformatować dysk w innej opcji” | D | zrobione |
| U3 | 2026-10-18 | C->A „nie implementujemy teraz… odzysk z ręcznie podłączonego kolektora, ale nie w 1.0” | B | zapisane |
| U4 | 2026-10-18 | „remove-media-trigger -- konieczne… rozumiem, że to był ruch w jedną stronę?” -- tak; teraz zdejmowana w oknach | D | zrobione |
| U5 | 2026-10-18 | „Wyłącz w GUI -- tak, ale z wyjaśnieniem, co to implikuje i jak włączyć z powrotem” | A | zrobione |
| U6 | 2026-10-18 | zvol w Przeglądaj kopię „light”: NTFS, EXT4 i inne znane; BitLocker/LUKS -- podanie klucza | B | zrobione (BitLocker bez testu na żywo) |
