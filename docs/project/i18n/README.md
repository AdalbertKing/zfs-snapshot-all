# Tłumaczenie GUI PL -> EN (zamrożone 2026-10-24)

`GUI-PL-EN-2026-10-24.json` to wynik przeglądu właściciela: 1404 unikalne teksty z `tui/` (1782 miejsca), po
jednym wierszu na tekst. Pola: `k` (id), `pl_code` (tekst w kodzie dziś), `pl` (tekst polski do użycia -- różny od
`pl_code` w 32 wierszach, gdzie właściciel poprawił polski), `en` (tłumaczenie), `origin` (`owner-ok` 1111,
`owner-edit` 76, `auto` 217 -- propozycja przyjęta bez przeglądu, decyzja właściciela 2026-10-24: „zatwierdzam”),
`unclear` (48 tekstów niezrozumiałych także po polsku; nowe brzmienie ustala się osobno z właścicielem),
`where` (plik:linia funkcja). Słownik terminów w polu `glossary` (m.in. relacja = relation, dysk podłączony =
connected).

Do wdrożenia: mechanizm z planu P0 (plik tekstów na język, funkcja tłumacząca w `wt-lib.sh` i Pythonie,
przełącznik w F10 i `zfs-backup gui --lang=en`); teksty w kodzie zostają polskim kluczem. Wiersze, które są
fragmentem kodu (wzorce sed/awk, rozwinięcia zmiennych), nie idą do tłumaczenia.
