# Wynik labu `hostscripts/` — skrypty hostów jako pliki, nie heredoki

Odpowiedź na `docs/discussions/LAB-HOSTSCRIPTS-2026-09-03.md`.

Wykonawca: wątek z dostępem do floty, 2026-09-03.
Gałąź testowana: **`04492a4`** — runbook pinuje `2f78d1f`, ale gałąź od tego czasu
ruszyła; różnica to **wyłącznie sam runbook** (docs), kod pod testem bajt w bajt
ten sam. Testowany czubek, bo to on się scali.
Odniesienie: **`main` `da1e8d4`** — zgodne z runbookiem, `main` nie ruszył.
Host: **pve9 (192.168.28.99)**, konto delegowane **`zfsbackup`**.

**Werdykt: wszystkie trzy własności potwierdzone. Jedna przewidziana różnica nie
wystąpiła i jest to poprawne — powód zmierzony, opisany niżej.**

## Odstępstwo od runbooka (dodane, nie pominięte)

Runbook nie mówi o wstrzymaniu autoaktualizacji, a `update-control.sh` chodzi co
godzinę o :15 i robi `git merge --ff-only`. Krok 1 zostawia repo na **odłączonej
głowie** (`git checkout --detach`), więc trafienie w tę minutę byłoby kolizją.
Założony `update-hold` na czas labu, zdjęty w rozbiórce. Warto dopisać do runbooka.

## Tabela wyników

| krok | co | predykcja | wynik |
|---|---|---|---|
| 0 | stan przed | markery v9/v7/v36/v6, brak `alert-env.sh` | **v9/v7/v36/v6**, brak po obu stronach (root i konto), kolejka 7 wpisów |
| 1 | `--check-only` z gałęzi | 4× „present but not the checkout's copy", `alert-env.sh missing` ×2 | **dokładnie tak** (root + `/home/zfsbackup/alert-env.sh missing`) |
| 1 | czy `--check-only` coś zapisał | nie | **`md5sum -c` OK ×4, mtime bez zmian**, `alert-env.sh` nadal nie ma |
| 2 | `deploy.sh` | 5× „installed … from hostscripts/" | **5×**, plus 3 pliki dla konta (`alert-env`, `notify-fail`, `notify-warn`) |
| 2 | `cmp` checkout vs zainstalowane | 5× identyczne | **SAME ×5** |
| 2 | `--check-only` po wdrożeniu | ≥5 „present (current)" | **5** |
| 2 | drugi zwykły przebieg | 5× „already current" | **5** |
| 3a | `notify-fail` jako root, env bije config | wpis w `/tmp/lab-q`, rc=0 | **rc=0**, `1788468425 ALERT lab job lab detail` |
| 3b | to samo z konta delegowanego | j.w. | **rc=0**, wpis poprawny |
| 3c | digest na kopii kolejki, `mail` stubowany | nagłówek i tabela jak w prawdziwym | **rc=0**, `pve9 … STAN: OK`, blok stanu + tabela przebiegów |
| 3d | brak `alert-env.sh` obok skryptu | głośna odmowa, rc=1 | **rc=1 dla wszystkich trzech**: `cannot source alert-env.sh next to this script` |
| 3e | `diff` starego i nowego digestu | tylko 2 klasy różnic | **1 klasa** — patrz niżej, poprawnie |
| 4 | rollback na `main` | stary `deploy.sh` nadpisuje, markery wracają | **v9/v7/v36/v6 z powrotem**, `alert-env.sh` zostaje jako nieużywany |
| 4 | czy przywrócone skrypty działają | (runbook nie pyta) | **dodane: rc=0** dla `notify-fail` i `alert-digest` po rollbacku |

## Przewidziana różnica, która nie wystąpiła — i dlaczego to poprawne

Runbook przewiduje w kroku 3 **dwie** klasy różnic między starym a nowym digestem:

1. blok preambuły → jedna linia `. "$(dirname "$0")/alert-env.sh" …` — **wystąpiła**,
   to całość 43-liniowego diffa (35 linii preambuły znika, 6 linii wchodzi);
2. `${ZFS_ALERT_EMAIL:-<adres>}` → `${ZFS_ALERT_EMAIL:-root}` — **nie wystąpiła**.

Powód zmierzony, nie zgadnięty: na pve9 **obie** wersje mają ten sam awaryjny
`${ZFS_ALERT_EMAIL:-root}` (stary: linia 1098, nowy: 1069), a prawdziwy adres
(`lurk@lurk.com.pl`) siedzi w `/etc/zfs-alert.conf`, który obie czytają tak samo.
Adres nigdy nie był tu wpieczony w skrypt, więc klasa 2 nie miała jak powstać.

**Na hoście, gdzie `deploy.sh --email=` wrenderował adres w heredok, ta różnica
wystąpi** i będzie oznaczać realną zmianę: adres przestaje być w skrypcie, a
zaczyna wyłącznie w configu. Na tej flocie nie ma jak tego sprawdzić — wszystkie
hosty biorą adres z `/etc/zfs-alert.conf`.

## Uwaga do własności 3 (rollback)

Rollback jest czysty, ale zostawia `alert-env.sh` po **obu** stronach (root i konto)
jako plik, którego stare skrypty nie czytają. Runbook to przewiduje i nazywa
nieszkodliwym — potwierdzone: stary `notify-fail` i stary `alert-digest` po
rollbacku działają (rc=0), bo niosą własną preambułę. W rozbiórce skasowałem oba
ręcznie, zgodnie z runbookiem.

## Czego nie próbowano

- wdrożenia na hoście, gdzie adres alertów jest wrenderowany w heredok (patrz wyżej);
- ścieżki `--email=` przy wdrożeniu z gałęzi;
- realnego wysłania maila — `mail` był podstawiony stubem, żeby nie ruszać
  produkcyjnej kolejki ani nie wysyłać poczty z labu;
- kroku „po scaleniu sprawdzić `v37` na reszcie floty" — PR jeszcze nie scalony.

## Stan hosta po labie

`main` `da1e8d4`, gałąź `main` (nie odłączona głowa), `update-hold` zdjęty,
markery v9/v7/v36/v6, `alert-env.sh` usunięte po obu stronach, `/tmp/lab-*`
i kopia sprzed labu skasowane. **Produkcyjna kolejka alertów nietknięta — 7 wpisów
przed labem i 7 po**; wszystkie testy szły na kopiach (`/tmp/lab-queue`, `/tmp/lab-q*`).
