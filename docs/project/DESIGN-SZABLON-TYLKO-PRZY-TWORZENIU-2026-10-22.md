# Szablon tylko przy tworzeniu (2026-10-22)

Decyzja właściciela z 2026-10-22: „Szablon/profil jest tylko pomocnikiem, szablonem żeby nie
ustawiać wszystkiego odrębnie. Potem jest zbędny dla relacji. Chyba, że znowu chcemy ją nim
poczęstować.” Wszystkie trzy punkty idą w jednym zakresie: „Chcę wszystkie”.

**Zasada.** Po plik `profiles/*.conf` sięgają tylko dwie rzeczy: utworzenie relacji oraz
świadome nałożenie szablonu („Użyj szablonu”, `edit-relation --profile=P`). Każda inna zmiana
istniejącej relacji pracuje na jej bloku `[relation:NAZWA]` i na jej sekcjach w configu.

## Gdzie dziś relacja czyta plik szablonu

Mapa z 2026-10-22, plik `zfs-backup.sh`.

| czynność | ścieżka | stan |
|---|---|---|
| set-tiers, set-transfer, pauza i wznowienie, set-endpoint, remove-source, add-source lokalny | blok i sekcje | dobrze |
| **add-source zdalny** | `cmd_add_source` → `activate-client` → `apply_client_profile_choice 1 "$PROFILE"` (~12241) → `ensure_cron_config ... PLAN_NEEDS_PROFILE` (~3062, `load_active_profile`) → `emit_client_sections` (regen ~4728: `profile_emit "$PROFILE_DS_FILE"`, `_tier_sched`, `stagger_send_expr`; drabina ~4882; źródło `emit_remote_source_prune` → `profile_reload_if_stale`, `source_retention_fragment`) | **czyta plik**. Zmierzone na pve10: bez `d30h24.conf` pada `add-source ab hdd/db --yes`. |
| **zmiana relacji lokalnej** w karcie | `cmd_edit_relation` → `run_local_relation_change` → `cmd_local_backup --replace` (~8424 `load_active_profile` bezwarunkowo) | **czyta plik** przy każdej zmianie |
| **zmiana migawek zdalnych** w karcie | `activate_snaponly` → `snaponly_prepare_workfile` (`rerender=1` zawsze przy edycji) → `emit_snaponly_sections` (~11600 `die "snaponly: profile ... not found"`) | **czyta plik** przy każdej zmianie |
| **import** | `cmd_import_relation` → `add-client --profile=NAZWA` (~9207 `profile_validate_file`) albo `local-backup` (~8424) | **czyta plik**, choć eksport niesie cały blok (`"relation":{...}`, ~18008) |
| „Użyj szablonu” | `edit-relation --profile=P` → `activate-client --regenerate` | czyta plik, i słusznie |

## Naprawa

1. **add-source zdalny.** Gdy relacja już istnieje i ma blok, a pliku szablonu nie nakładamy
   od nowa, nowy dataset powstaje jako **klon sekcji sąsiada z tej samej relacji**, tak jak
   robi to dziś `local_source_change`:
   - `[dataset:<cel>]` z `side = target`: podmiana nagłówka, `src` (część po `:`), `notify`
     (`NAZWA-<basename>`). Rozsunięte minuty i flagi zostają jak u sąsiada.
   - `[prune:konto@host:<ds>]` z `side = source`, jeśli relacja go ma: podmiana nagłówka,
     `notify` (`NAZWA-src-<basename>`), `recursive` (`is_recursive_root`).
   - `[prune:<cel>]` z `side = target` (drabina na celu), jeśli relacja go ma: tak samo.
   - `PLAN_NEEDS_PROFILE = 0` w tym trybie. Nic nie woła `load_active_profile` ani
     `profile_reload_if_stale`.
   - Pierwsza kopia nowego datasetu, `MANAGED_DATASETS` i zgoda na źródle bez zmian.
2. **Zmiana relacji lokalnej i migawek zdalnych.** Przebudowa z szablonu tylko przy
   zmianie szablonu. Każda inna zmiana idzie na bloku i sekcjach, tak jak set-tiers.
3. **Import.** Relacja powstaje z bloku zapisanego w eksporcie (`relation`), a `--profile`
   służy tylko jako etykieta. Brak pliku szablonu na docelowym kolektorze nie jest błędem.

## Dowód (sam, przed recenzentem)

- **Na żywo na pve10**, wszystko z UKRYTYMI plikami (`profiles/*.conf` przeniesione na bok):
  - add-source i remove-source na ab;
  - zmiana relacji lokalnej (karta);
  - zmiana migawek zdalnych;
  - eksport → usunięcie → import cb i ab;
  - kontrola: „Użyj szablonu” z ukrytym plikiem ma odmówić czytelnie.
- **Test regresji w `zfsbackup`** (add-source bez pliku szablonu, import bez pliku), oparty na
  kontroli negatywnej na main.
- **Porównanie configu** po add-source: klon a dotychczasowa droga z szablonem dają te same
  sekcje, poza minutami (`state-diff`).
- **Suity:** `zfsbackup`, `localbackup` (jako tester), `tui`, `snaponly` na pve9; reszta w CI.

## Wynik (2026-10-22, `kamp/no-profile`)

1. **add-source zdalny.** `PLAN_CLONE`: dla istniejącej relacji z blokiem i sąsiadem nowe sekcje
   kopiuje `relation_sibling` + `clone_relation_section` (cel, sprzątanie źródła, drabina celu),
   `PLAN_NEEDS_PROFILE=0`. Na żywo na pve10 z ukrytym `d30h24.conf`: `add-source ab hdd/db --yes` rc 0,
   sekcje i cron kompletne, pierwsza kopia OK; potem `remove-source`.
2. **Zmiana relacji lokalnej i migawek zdalnych.** Po sprawdzeniu: `edit-relation` przyjmuje tylko
   `--profile`/`--source-profile` (i słowa szczebli), a GUI woła go wyłącznie przy „Harmonogram →
   inny szablon”. Szczeble, retencja źródła, silnik i datasety idą osobnymi czasownikami na bloku.
   Czyli ta ścieżka czyta plik tylko przy świadomym nałożeniu szablonu -- zgodnie z zasadą, bez zmian.
3. **Import.** Brak pliku szablonu → `import_helper_profile` buduje ukryty szablon pomocniczy z bloku
   `relation` w eksporcie (katalog tymczasowy, `PROFILE_USER_ROOT`), rekord dostaje z powrotem nazwę
   pierwotnego szablonu, blok przywraca `import_restore_relblock`. Bez bloku w pliku -- odmowa z
   poleceniem. Na żywo: eksport cb → usunięcie → import z ukrytym `d7h24.conf`: rc 0, `PROFILE=d7h24`,
   `FAMILY_BORN_AT` zachowane, lustro z `-M`, blok jak przed (poza pustą linią).
4. **Całość bez katalogu `profiles/`** (pve10): show-tiers, show-config, list-jobs, monitor, export,
   set-transfer, set-tiers, activate -- rc 0; „Użyj szablonu” (`edit-relation --profile=…`) odmawia
   czytelnie (plik brakuje), i tak ma być.

## Poza zakresem (zapisane)

- Drabina na jednej rodzinie w bloku relacji (`M12W4D7H24`, prośba właściciela z 2026-10-22).
  Generator przyjmuje dziś jeden licznik na szczebel z GFS, więc szablon wycofany z paczki
  szablonów.
