# zfsbackup

[English](README.md) · **Polski**

Migawki ZFS, kopie, retencja i monitoring dla małych flot Proxmox VE — sterowane z jednego hosta,
**kolektora**, ustawiane w tekstowym GUI w konsoli serwera, wykonywane przez cron. Czysty bash
i Python 3 dla GUI; bez demona, bez bazy danych, bez osobnego agenta na źródłach (tam działają te
same skrypty).

**Dla kogo:** dla administratorów od jednego do kilkudziesięciu hostów Proxmox VE na ZFS, którzy
chcą kopii poza hostem z historią, retencji w progach, alertu, gdy kopia przestaje przychodzić,
i odzysku, który da się przejść w konsoli — bez stawiania serwera kopii.

- **Kopia** (backup) — kolektor ściąga kopie ze źródła i trzyma własną historię; do pozostałych
  przypadków **lustro**, **kopia lokalna**, **migawki lokalne i zdalne**.
- **Retencja na każdym szczeblu** (godzinne, dobowe, tygodniowe, miesięczne, roczne), na kopii i na źródle.
- **Repliki** na USB albo drugą pulę, raz na noc, opcjonalnie szyfrowane (`prepare-media --encrypt`).
- **Monitor i dzienny raport mailem**, gdy kopia przestaje przychodzić; **odzysk** z GUI.
- Zna Proxmoxa: nazwy datasetów VM/CT, wyciszanie gości, delegowane konta bez roota, kopie lokalne
  replik pvesr (`--passive`).
- Istniejących migawek na źródle nie zgaduje: kreator pyta, czy robi je ktoś inny (przejąć je,
  `--passive`), czy to resztki (`--own-snapshots`).

Zrzut ekranu GUI (okno F3 Relacje) jest w [README.md](README.md); te same ekrany po polsku pokazuje
[tutorial](https://adalbertking.github.io/zfsbackup/tutorial/).

## Wymagania

- Proxmox VE (albo Debian z OpenZFS) na każdym hoście, który bierze udział: na kolektorze i na
  każdym źródle.
- Root na kolektorze do instalacji; dostęp SSH roota z kolektora do źródła na jednorazowe
  przygotowanie. Same zadania mogą chodzić na koncie delegowanym (`--backup-user`).
- `zfs`, `cron`, `flock`, `mbuffer`, `ssh`, `awk`, `zstd` (domyślny kompresor; `pigz` jako
  alternatywa), `python3` dla GUI i transport poczty (zgodny z `sendmail`) dla alertów. `deploy.sh`
  sprawdza zależności silników i mówi, czego brakuje; `ssh` tylko tam, gdzie relacja sięga innego hosta.

## Szybki start

Na kolektorze, jako root:

```bash
git clone https://github.com/AdalbertKing/zfsbackup.git /root/scripts/zfs-snapshot-all
cd /root/scripts/zfs-snapshot-all
./deploy.sh --backup-user=zfsbackup
zfs-backup gui --lang=pl    # F3 Relacje, Ins: kreator zakłada pierwszą relację
```

Do przygotowania kolektor potrzebuje dostępu SSH roota do źródła; kreator sam instaluje tam pakiet.
GUI startuje po angielsku; `--lang=pl` (albo `[gui] language = pl` w F10 Ustawienia) przełącza je na
polski. Wyjście poleceń jest zawsze po angielsku.

Zainstalowane hosty aktualizują się z tego repozytorium raz na godzinę (`update-control.sh`);
`zfs-backup --version` pokazuje wydanie i rewizję deweloperską, z której je zbudowano (`RELEASE-OF`).

## Zanim mu zaufasz

To narzędzie administratora. Działa jako root, zakłada i **usuwa** migawki ZFS na kolektorze i na
źródłach zgodnie z ustawioną retencją, a odzysk „na miejsce” może nadpisać dataset.

- Przetestuj odzysk na własnych danych, zanim będzie potrzebny: kopia, z której nigdy nic nie
  odzyskano, nie jest jeszcze kopią. [Tutorial](docs/tutorial/index.html) prowadzi przez to krok po kroku.
- Retencja usuwa. Przed pierwszym biegiem nowej relacji sprawdź jej szablon (F5), a migawki robione
  przez inne narzędzie (pvesr, inny kolektor) zostaw w trybie `--passive`.
- Trzymaj drugą kopię poza kolektorem (replika na USB albo drugą pulę, F6) — jeden kolektor to jeden
  punkt awarii.
- Bez gwarancji (zob. [LICENSE](LICENSE)); zacznij od [esencji](docs/pl/ESENCJA.md).

## Dokumentacja

Każdy temat jest w obu językach: najpierw jednostronicowa esencja, potem pełne przewodniki
i instrukcja techniczna. **Interaktywny tutorial**: złóż swój wariant z klocków (jeden host, dwa hosty, klaster
Proxmox z pvesr, A > B <> C) i przejdź go na prawdziwych ekranach GUI albo poleceniach CLI, po polsku i po angielsku:
[https://adalbertking.github.io/zfsbackup/tutorial/](https://adalbertking.github.io/zfsbackup/tutorial/). Ta sama strona leży w [docs/tutorial/index.html](docs/tutorial/index.html) i działa też
pobrana, bez sieci.

| | Polski | English |
|---|---|---|
| **esencja (jedna strona)** | [docs/pl/ESENCJA.md](docs/pl/ESENCJA.md) | [docs/en/ESSENTIALS.md](docs/en/ESSENTIALS.md) |
| jak to działa | [docs/pl/JAK-TO-DZIALA.md](docs/pl/JAK-TO-DZIALA.md) | [docs/en/HOW-IT-WORKS.md](docs/en/HOW-IT-WORKS.md) |
| wdrożenie na Proxmoxie | [docs/pl/WDROZENIE-PROXMOX.md](docs/pl/WDROZENIE-PROXMOX.md) | [docs/en/DEPLOYMENT-PROXMOX.md](docs/en/DEPLOYMENT-PROXMOX.md) |
| kolektor, dwa źródła, replika | [docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md](docs/pl/WDROZENIE-KOLEKTOR-DWA-ZRODLA-REPLIKA.md) | [docs/en/DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md](docs/en/DEPLOYMENT-COLLECTOR-TWO-SOURCES-REPLICA.md) |
| ściąga poleceń | [docs/pl/KOMENDY.md](docs/pl/KOMENDY.md) | [docs/en/COMMANDS.md](docs/en/COMMANDS.md) |
| odzysk z repliki | [docs/pl/ODZYSK-Z-REPLIKI.md](docs/pl/ODZYSK-Z-REPLIKI.md) | [docs/en/RESTORE-FROM-REPLICA.md](docs/en/RESTORE-FROM-REPLICA.md) |
| pauza i twarda blokada | [docs/pl/PAUZA-I-BLOKADA.md](docs/pl/PAUZA-I-BLOKADA.md) | [docs/en/PAUSE-AND-DISABLE.md](docs/en/PAUSE-AND-DISABLE.md) |
| instrukcja techniczna (opcje silników, config, alerty) | [docs/pl/REFERENCJA.md](docs/pl/REFERENCJA.md) | [docs/en/REFERENCE.md](docs/en/REFERENCE.md) |
| przykłady configu | [docs/pl/PRZYKLADY-CONFIGU.md](docs/pl/PRZYKLADY-CONFIGU.md) | [docs/en/CONFIG-EXAMPLES.md](docs/en/CONFIG-EXAMPLES.md) |
| dostarczane szablony retencji | | [profiles/README.md](profiles/README.md) |

Zmiany między wydaniami: [CHANGELOG.md](CHANGELOG.md) (po angielsku).

## Zgłoszenia i bezpieczeństwo

Błędy i pomysły: GitHub Issues (po polsku też można). Jak trafiają zmiany (to repozytorium jest
generowane z repozytorium deweloperskiego): [CONTRIBUTING.md](CONTRIBUTING.md). Podatność — nie
zakładaj publicznego zgłoszenia; zob. [SECURITY.md](SECURITY.md).

## Wesprzyj autora

zfsbackup jest darmowy i taki zostanie. Jeśli oszczędza ci czas albo nieprzespaną noc, możesz
wesprzeć dalszą pracę — gwiazdka na GitHubie i dobre zgłoszenie błędu też pomagają.

[☕ Postaw kawę (Buy Me a Coffee)](https://buymeacoffee.com/tel4891350z)

## Autor i licencja

Wojciech Król (Adalbert King). MIT — zob. [LICENSE](LICENSE).
