# Audyt przed publikacją 1.0: dane prywatne i plan podmiany (2026-10-27)

Status: **RAPORT DO AKCEPTACJI WŁAŚCICIELA. Nic nie podmienione.** Podstawa:
`PLAN-WYDANIA-PUBLICZNEGO-2026-10-23.md` (dwa repo, bez przepisywania historii) i
`DESIGN-REPO-WYDAN-2026-10-24.md` (repo wydań `AdalbertKing/zfsbackup`, eksport `release/publish.sh`
według `release/MANIFEST`, podmiana `release/scrub.sed`). Inwentarz zrobił agent haiku na drzewie
`e3eaf95d`; każde trafienie niżej sprawdzone `grep` w sesji.

## 1. Co gdzie trafia

| | repo dev `zfs-snapshot-all` | repo wydań `zfsbackup` |
|---|---|---|
| widoczność | prywatne do 1.0 (i dalej) | publiczne; hosty ciągną z niego co godzinę |
| zawartość | wszystko | tylko `release/MANIFEST` po `scrub.sed` |
| historia | pełna, nieprzepisywana | rośnie liniowo, nigdy `--force` (hosty: `merge --ff-only`) |
| `test/`, `docs/internal/`, `docs/project/`, inne `docs/*`, `.github/workflows/`, `CLAUDE.md`, `AGENTS.md` | tak | **nie** (sprawdza `test/release`) |
| skrypty, `tui/`, `hostscripts/`, `profiles/`, `docs/pl`, `docs/en`, `LICENSE` | tak | tak |
| od tego PR: `docs/tutorial/`, `README.pl.md`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`, `.github/FUNDING.yml`, `.github/ISSUE_TEMPLATE/`, `.github/pull_request_template.md` | tak | tak |

Wniosek dla repo dev: zostaje prywatne, jego dane (około 700 trafień adresów i nazw firm w `test/`,
`docs/internal/`, `docs/project/`, `PROJECT_STATUS.md`) nie wychodzą, więc ich podmiana nie jest
warunkiem publikacji. Krok 2 planu z 2026-10-23 (podmiana w testach) robi się potrzebny dopiero, gdy
testy miałyby iść do repo publicznego -- to pytanie nadal otwarte (§4).

## 2. Co ZOSTAJE po `scrub.sed` w pakiecie publicznym

`scrub.sed` przepisuje 192.168.28.x, 192.168.11.x, 10.98.0.x i „Metropolis”. Poniższe przechodzi.
**Uwaga: to już jest publiczne** -- `zfsbackup` od wydania v1.0 (2026-10-25) zawiera te same pliki
(sprawdzone przez API: `hostscripts/alert-digest.sh` ma `kancelaria`, `snapget.sh` adres e-mail).
Historii `zfsbackup` nie przepisujemy (hosty `ff-only`), więc podmiana działa od następnego wydania;
stare commity zostają widoczne.

| # | co | gdzie | ocena |
|---|---|---|---|
| A1 | `kancelaria`, `kancelaria.net` (klient) | `hostscripts/alert-digest.sh:151,298,488,963`; `docs/pl/PRZYKLADY-CONFIGU.md:65`, `docs/en/CONFIG-EXAMPLES.md:65` („wzorzec Kancelaria”) | **podmienić** |
| A2 | `A-TASSA` / `a-tassa` (klient) | `zfs-backup.sh:7457`, `hostscripts/capacity-guard.sh:4` | **podmienić** |
| A3 | `vsql2` (VM klienta) | `zfs-quiesce-helper.sh:58,70,96,442,518`, `snapget.sh:1187` | podmienić (np. „gość Windows z SQL Server”) |
| A4 | `site-a.net` (wynik scrubu `metropolis.net`) | `deploy.sh:5918`, `tui/new-relation.sh:161` | podmienić na `example.org` -- reguła w `scrub.sed` |
| A5 | 10.99.0.x (adresy VPN) | `zfs-backup.sh:9921,13333,13334` | reguła w `scrub.sed` (np. → 203.0.113.) |
| A6 | e-mail autora `lurk@lurk.com.pl` | `delsnaps.sh:5`, `snapget.sh:5`, `snapsend.sh:5` | **decyzja właściciela**: zostawić jako kontakt autora albo usunąć |
| A7 | nazwy hostów labu `pve0/1/2/9/9b/10/11` w komentarzach („Measured … on pve9”) | kilkaset linii, głównie `zfs-backup.sh`, `deploy.sh`, `zfs-restore.sh`, `tui/zfs-tui.py` | zostawić: domyślne nazwy węzłów Proxmoxa, nic nie zdradzają |
| A8 | daty pomiarów i opisy incydentów w komentarzach („Found live on Site-A pve1, 2026-08-01”) | ~40 linii | zostawić, gdy nie nazywają klienta (po A1-A3 nie nazywają) |
| A9 | `Wojciech Król` (autorstwo) | `LICENSE`, README, `delsnaps.sh:4`, `tui/zfs-tui.py:2766` | zostaje (zamierzone) |
| A10 | ucięty klucz publiczny `restrict ssh-ed25519 AAAAC3Nza…` | `docs/en/PAUSE-AND-DISABLE.md:265`, `docs/pl/PAUZA-I-BLOKADA.md:266` | zostawić: przykład bez treści klucza |

Czyste: klucze prywatne, hasła, tokeny, odciski SHA256, ścieżki Windows (`D:\`, `C:\Users`), Sedina,
Dąbrowska, wg1, OPNsense, NethServer. Adresy 10.0.0.x i 192.168.1.x / 192.168.5.x w `docs/pl|en`
i w tutorialu to adresy przykładowe wybrane przy czystce dokumentacji -- zostają.

## 3. Plan podmiany (po akceptacji, osobna paczka)

1. `release/scrub.sed`: dopisać reguły A4 (`site-a\.net` → `example.org`, po regule Metropolis)
   i A5 (`10\.99\.0\.` → `203.0.113.`); w `publish.sh` i `test/release` rozszerzyć kontrolę
   „nic nie zostało” o `kancelaria`, `a-tassa`, `vsql2`, `10.99.0.`, `site-a.net`.
2. A1-A3 w źródle (komentarze i dwa przykłady w docs): nazwy neutralne („kancelaria” → „biuro”,
   „A-TASSA” → „host z dużą dzienną zmianą”, „vsql2” → „gość z SQL Server”). Same komentarze,
   zero zmiany zachowania; idzie w repo dev, bo komentarze to pomiary, a nazwa klienta nic do nich
   nie wnosi. Dotyka `zfs-backup.sh`, `deploy.sh`, `tui/new-relation.sh` -- po scaleniu gałęzi `gui/*`,
   żeby nie było konfliktów.
3. A6 według decyzji właściciela.
4. Publikacja następnego wydania (`release/publish.sh`) **tylko za zgodą właściciela**.

## 4. Do decyzji właściciela

- A6: e-mail autora w nagłówkach trzech skryptów -- zostaje czy znika?
- Akceptacja planu §3 (kolejność: po scaleniu `gui/*`).
- Czy testy idą kiedyś do repo publicznego (wtedy potrzebny krok 2 planu z 2026-10-23: podmiana
  ~3600 trafień w `test/`).
- Konto Buy Me a Coffee: zakłada właściciel (asystent nie zakłada kont); potem jedna linia w
  `.github/FUNDING.yml` i link w obu README (komentarze `Buy Me a Coffee` w plikach wskazują miejsce).
- `SECURITY.md` odsyła do prywatnego zgłaszania podatności GitHuba: trzeba je włączyć w
  `zfsbackup` → Settings → Code security → Private vulnerability reporting.
