# Tłumaczenie GUI PL -> EN (zamrożone 2026-10-24)

`GUI-PL-EN-2026-10-24.json` to wynik przeglądu właściciela: 1404 unikalne teksty z `tui/` (1782 miejsca), po
jednym wierszu na tekst. Pola: `k` (id), `pl_code` (tekst w kodzie dziś), `pl` (tekst polski do użycia -- różny od
`pl_code` w 32 wierszach, gdzie właściciel poprawił polski), `en` (tłumaczenie), `origin` (`owner-ok` 1111,
`owner-edit` 76, `auto` 217 -- propozycja przyjęta bez przeglądu, decyzja właściciela 2026-10-24: „zatwierdzam”),
`unclear` -- 48 tekstów niezrozumiałych także po polsku: 45 dostało nowe brzmienie (`origin` = `owner-reworded`,
właściciel zatwierdził 2026-10-24; `pl` to nowy tekst polski, `en` jego tłumaczenie), 3 zostają (u13, u244 -- kod
albo tekst testowy; u352 -- ekran nieużywany),
`where` (plik:linia funkcja). Słownik terminów w polu `glossary` (m.in. relacja = relation, dysk podłączony =
connected).

Do wdrożenia: mechanizm z planu P0 (plik tekstów na język, funkcja tłumacząca w `wt-lib.sh` i Pythonie,
przełącznik w F10 i `zfs-backup gui --lang=en`); teksty w kodzie zostają polskim kluczem. Wiersze, które są
fragmentem kodu (wzorce sed/awk, rozwinięcia zmiennych), nie idą do tłumaczenia.

## Stan 2026-10-24 (dograne)

Wszystkie decyzje właściciela ze strony przeglądu naniesione: `owner-ok` 1261, `owner-edit` 92, `owner-reworded` 47,
`auto` 4. Ujednolicone według reguł właściciela: po angielsku „relation” (nie „relationship”), dysk po polsku
„podłączony / odłączony / po podłączeniu” (nie „włożony”, „w slocie”), po angielsku „connected / disconnected”.

