# FINISZ -- backlog paczek (od 2026-10-18, tydzień)

Tryb pracy (właściciel 2026-10-18): właściciel zgłasza uwagi w trakcie obserwacji,
implementer zapisuje je TUTAJ (numer, słowa właściciela) i łączy w paczki. Jedna paczka =
jedna gałąź = jeden PR, scalany po zielonym CI. Bez suit lokalnie (CI ~3 min). Na żywo na
pve9 tylko to, co widać w GUI. Recenzent i łatanie -- po paczkach.

Cel: każda funkcjonalność pakietu dostępna z GUI, z chudym odzyskiem.

## Paczki (kolejność)

| # | paczka | zawartość | stan |
|---|---|---|---|
| A | Cykl relacji w GUI | relacja nie-aktywna (1. kopia, czeka na źródło, zmiana adresu w toku): w oknie relacji jeden klawisz „dokończ” = następny krok (`seed` / `verify-endpoint` / `activate`), zamiast komendy do przepisania -- ZROBIONE (`d dokończ`, #609); wyłącz/włącz (`disable-client`/`enable-client`) -- czeka na decyzję: F8 Pauza już zatrzymuje relację | w toku |
| B | Chudy odzysk | F11 (#608); „Przeglądaj kopię” runda 1 -- ZROBIONE (F7 na F11: migawka RO, `mc`, odmontowanie; datasety plikowe); zvol (VM) -- runda 2; łańcuch C->A z pominięciem B -- decyzja właściciela | w toku |
| C | Retencja | wada `[prune:]` gubi `gfs=yes` -- ZROBIONE #610 (drabina `-G` na szczebel po stronie źródła; lądowiska płaskie; migawki zdalne przyjmują GFS); podgląd retencji źródła (`audit-source-retention`) w oknie relacji | w toku |
| D | Replika | `purge-replica-copy`, `remove-media-trigger` z okna repliki | do zrobienia |
| E | Suity | `test/tui` z selektorem sekcji; przegląd duplikatów w `zfsbackup`/`localbackup` (165 s i 143 s w CI); zmiana klawisza/ekranu nie ciągnie całego drzewa | do zrobienia |
| F | Uwagi z obserwacji | wpisy U1.. poniżej, zbierane do najbliższej paczki | otwarte |

Tylko CLI (świadomie, bez okna): `setup-server` (instalacja hosta), `move-to-client`,
`final-catchup`, `pause-writers`/`resume-writers` (deploy), `show-scope`, `test`, `help`.
Do decyzji właściciela, jeśli któreś ma mieć okno.

## Uwagi właściciela (U1..)

| # | data | słowa właściciela / co | paczka | stan |
|---|---|---|---|---|
