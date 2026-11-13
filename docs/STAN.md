# STAN — bieżący stan projektu

Zastępuje `docs/PROJECT_STATUS.md` (zamrożony 2026-11-13). Najwyżej 150 linii.
Odświeżany raz na wydanie (`docs/project/WORKFLOW.md` W9). Każda pozycja ma źródło;
pozycja bez dzisiejszego sprawdzenia jest tak oznaczona.

Stan na: 2026-11-13, `main` = `d09c6e87`.

## Wydanie

| co | wartość | źródło |
|---|---|---|
| ostatnia wersja | 1.0.21 (2026-11-13), zfsbackup `46135c2` = release of `d09c6e87` | `CHANGELOG.md`, `git ls-remote` zfsbackup |
| scalone, niewydane | brak | `CHANGELOG.md` |
| co blokuje `publish.sh --push` | każdy REV w stanie OPEN lub IMPLEMENTED | `release/review-gate.sh` |

## Recenzje

Kto ma ruch: job CI `ledger` w najnowszym biegu na `main`.

| REV | stan 2026-11-13 | źródło |
|---|---|---|
| REV-20261112-197 (`--source-keep`, quiesce) | APPROVED na `f3f95dab` (PR #1222); zamknięcie po stronie recenzenta | `remote-suite.sh derive origin/main` |

## Hosty

Odczyt 2026-11-13 16:18–16:25, po cronie :15 (`git log -1` w checkoucie roota i konta `zfsbackup`).

| host | rola | wersja | sprawdzone |
|---|---|---|---|
| pve9 (192.168.28.99) | lab, host suit | checkout deweloperski, nie wydanie | tak |
| pve9b (192.168.28.98) | lab | `46135c2b` (root; konta `zfsbackup` brak) | tak |
| pve10 (192.168.28.97) | lab | — | nie: klucz ssh odrzucony |
| pve11 (192.168.28.96) | lab | `46135c2b` (root i konto) | tak |
| site-A pve1 (192.168.28.9) | produkcja | `46135c2` (root i konto) | tak |
| site-A pve2 (192.168.28.8) | produkcja | `46135c2` (root i konto) | tak |
| Site-B pve0 (192.168.11.10) | produkcja | `46135c2` (root i konto) | tak |
| Site-B pve1 (192.168.11.11) | produkcja | `46135c2` (root i konto) | tak |
| trzecia firma | produkcja, osobny projekt | — | nie |

## Znane czerwone

Brak. Pełna suita `test/snapsend` 481/0 na `a51539aa` (pve9, 2026-11-13); CI 55/55 na PR #1224.

## Otwarte

- Backlog: `docs/project/FINISZ-BACKLOG.md`.
- Porządek na GitHubie przed kolejną firmą (właściciel, 2026-11-13): w historii zfsbackup nazwy
  klientów są w 8 z 57 commitów (HEAD czysty); repo dev publiczne. Propozycja czeka na decyzję.
