# STAN — bieżący stan projektu

Zastępuje `docs/PROJECT_STATUS.md` (zamrożony 2026-11-13). Najwyżej 150 linii.
Odświeżany raz na wydanie (`docs/project/WORKFLOW.md` W9). Każda pozycja ma źródło;
pozycja bez dzisiejszego sprawdzenia jest tak oznaczona.

Stan na: 2026-11-13, `main` = `0d60f6b1`.

## Wydanie

| co | wartość | źródło |
|---|---|---|
| ostatnia wersja | 1.0.20 (2026-11-12) | `CHANGELOG.md` |
| scalone, niewydane | sekcja `[Unreleased]` | `CHANGELOG.md` |
| co blokuje `publish.sh --push` | każdy REV w stanie OPEN lub IMPLEMENTED | `release/review-gate.sh` |

## Recenzje

Kto ma ruch: job CI `ledger` w najnowszym biegu na `main`.

| REV | stan 2026-11-13 | źródło |
|---|---|---|
| REV-20261112-197 (`--source-keep`) | odrzucony po rundzie 3 (PR #1214); runda 4 scalona (PR #1215), werdyktu jeszcze nie ma | `docs/internal/reviews/REV-20261112-197.md`, `responses/REV-20261112-197.md` |

## Hosty

Wersji na hostach dziś nie sprawdzano. Tabelę uzupełnia się przy najbliższym wydaniu,
odczytem z każdego hosta.

| host | rola | wersja | sprawdzone |
|---|---|---|---|
| pve9 (192.168.28.99) | lab, host suit | — | nie |
| pve9b (192.168.28.98) | lab | — | nie |
| pve10 (192.168.28.97) | lab | — | nie |
| pve11 (192.168.28.96) | lab | — | nie |
| produkcja | 7 serwerów czeka na wdrożenie (właściciel, 2026-11-13) | — | nie |

## Znane czerwone

| suita | przypadek | stan |
|---|---|---|
| `test/snapsend` | para „P -R -e over scaffolding only” | pada w każdym biegu (466/2 na 2026-11-13); do naprawy albo oznaczenia jako oczekiwana porażka (WORKFLOW W7) |

## Otwarte

- Backlog: `docs/project/FINISZ-BACKLOG.md`.
- Reguła W6 (klasa wady i reprodukcja w odmowie) czeka na przyjęcie przez recenzenta.
