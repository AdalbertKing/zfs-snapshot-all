# Wynik labu — `deploy.sh --draft-config` na prawdziwym parowaniu

Odpowiedź na `docs/discussions/LAB-DRAFT-CONFIG-2026-09-03.md`.

Wykonawca: wątek z dostępem do floty, 2026-09-03/04.
Hosty: **A = pve9** (192.168.28.99, kolektor), **B = pve10** (192.168.28.97, peer),
pula `hdd`, konto zadań `zfsbackup`, jako root.
SHA w chwili labu: **`fcc5a26c`** na starcie, **`4c00563b`** na końcu (host
przeskoczył w trakcie — patrz błąd 2 niżej). PR #315 był już scalony.

**Werdykt: wszystkie sześć własności (A–F) potwierdzone.** Znaleziono
**trzy błędy w runbooku** i **dwa znaleziska poboczne**, w tym jedno
bezpieczeństwa. Rekomendacja co do losu komendy — na końcu.

## Krok 0 — czy flota tego kiedykolwiek użyła

Zmierzone na **wszystkich siedmiu** hostach:

| sprawdzenie | wynik |
|---|---|
| pliki `*.suggested` w `/root/scripts/pairing/` | **0** |
| `grep 'draft-config'` w `cron.log` roota | **0** |
| `grep 'draft-config'` w `cron.log` kont delegowanych | **0** |
| `grep 'draft-config'` w `/root/.bash_history` | **0** |

Dodatkowo w repozytorium **nic tej komendy nie woła** — poza własną definicją i
tekstem pomocy w `deploy.sh` występuje wyłącznie w dokumentach projektowych.
Ścieżka wysokopoziomowa (`add-client`/`activate`, `cmd_seed`) idzie przez
`resolve_mode_datasets`.

## Tabela wyników

| własność | wynik |
|---|---|
| **(A)** draft na parowaniu `pull` | plik powstał; **dokładnie dwie** stanzy (`root1`, `root2` — zadeklarowane i obecne); `hdd/lab-draft/root1 ma 2 datasetow potomnych`; `recursive = flat` **tylko** przy `root1`; `-K /home/zfsbackup/.ssh/pairing-…_ed25519` (klucz **konta zadań**, nie roota); `-k …_known_hosts` obecne; **`-p` nieobecne** przy porcie 22 |
| **(B)** zadeklarowany, nieistniejący | `# UWAGA: zadeklarowane w parowaniu, ale NIE ISTNIEJA na 192.168.28.97:` → `hdd/lab-draft/ghost` — jako ostrzeżenie, **nie** jako stanza |
| **(C)** obecny poza parowaniem | sekcja `NIE OBJETE TA RELACJA` z podpowiedzią `--pair --peer=… --peer-datasets="hdd/lab-draft/root1 hdd/lab-draft/root2 hdd/lab-draft/ghost <nowy>"`; głębsze **policzone, nie wypisane** (`… oraz 3 glebszych (pominiete, to widok pierwszego poziomu)`) |
| **(D)** idempotencja | drugi przebieg: `sha256sum -c` **OK** (plik nadpisany identyczną treścią); crontab roota `61ed9a66447f` → bez zmian; crontab `zfsbackup` `8d88b637d729` → bez zmian; plików nowszych w `/etc/zfs-snapshot-all`: **0 przed i 0 po** |
| **(E)** rola `push` | nagłówek `Kandydaci LOKALNE (rola: push do '192.168.28.99')`, stanzy z lokalnego `zfs list`, pole **`dst =`** zamiast `src =`, `recursive = flat` tylko przy `root1`, `-K`/`-k` na klucze konta zadań |
| **(F)** przed `--join` | `rc=1`, `FATAL: could not list datasets on 192.168.28.97 -- has --join run there yet?`, **plik nie powstał** |

## Trzy błędy w runbooku

### 1. `--draft-config` wymaga `--pair` — a runbook każe wołać bez niego

Runbook (kroki 1–4) używa formy:

```
bash deploy.sh --peer=<B> --draft-config
```

`do_draft_config` jest osiągalne **wyłącznie przez `do_pair`**, a ten uruchamia
się tylko przy `PAIR_MODE=1`, które ustawia jedynie `--pair` (`deploy.sh:455`)
oraz `--unpair`. Poprawna forma:

```
bash deploy.sh --pair --peer=<B> --draft-config
```

**To nie jest błąd kosmetyczny.** Forma z runbooka nie kończy się komunikatem
o złym użyciu — spada do zwykłej ścieżki i uruchamia **PEŁNE WDROŻENIE HOSTA**:
`git pull` w Fazie 2, przeinstalowanie skryptów, praca na crontabie. U mnie
przeszła fazy 1–8 i padła dopiero na Fazie 8g. Komenda, która miała tylko
narysować plik komentarzy, zmieniła stan hosta.

### 2. `update-hold` NIE chroni przed `deploy.sh`

Krok 0 każe założyć `update-hold` „żeby host nie ruszył". Hold bramkuje
`update-control.sh --self-update`, ale **nie** własny `git pull` z Fazy 2
`deploy.sh`. Skutkiem błędu 1 host przeskoczył `fcc5a26c → 4c00563b` mimo
założonego holdu; `deploy.sh` w tym samym przebiegu **drukuje**, że aktualizacje
są wstrzymane — i pobiera repo dwie fazy wcześniej.

### 3. `ghost` blokuje `--join` na peerze — stan dla (B) buduje się inaczej

Runbook deklaruje przy `--pair` nieistniejący `hdd/lab-draft/ghost`, żeby (B)
miało co pokazać. Peer **odmawia** `--join`:

```
FATAL: the collector requested 'hdd/lab-draft/ghost' … but no such dataset
exists on this host -- refusing to draft a scope around a request that cannot
be satisfied
```

Własność (B) udało się mimo to zaobserwować, bo `--join` zdążył **założyć konto
i wpisać klucz** zanim odmówił — a `--draft-config` potrzebuje tylko tego.
Trzeba to napisać wprost: **draft powstał na parowaniu, które peer uznał za
NIEDOKOŃCZONE** (żaden scope nie został skomitowany, `peers/*.scope*` = 0).
Kto powtarza lab, niech się tego spodziewa i nie uzna za regresję.

Drobiazg do (C): runbookowy `hdd/lab-draft/outside` wylądował wśród
„3 glebszych (pominiete)", nie jako wypisany nieobjęty — bo leży trzy poziomy
głęboko. Żeby zobaczyć go wypisanego, musiałby być płytszy (np.
`hdd/lab-draft-outside`).

## Dwa znaleziska poboczne

### Bezpieczeństwo: trzy hosty mają TEN SAM prywatny klucz roota

```
pve9  256 SHA256:qyDsuCE9FmUCDuHi9Q4eHR6UXb2FoGJ1ntn6QoTsDYg root@pve9
pve9b 256 SHA256:qyDsuCE9FmUCDuHi9Q4eHR6UXb2FoGJ1ntn6QoTsDYg root@pve9
pve10 256 SHA256:qyDsuCE9FmUCDuHi9Q4eHR6UXb2FoGJ1ntn6QoTsDYg root@pve9
```

Identyczny odcisk i komentarz `root@pve9` na wszystkich trzech — pozostałość po
klonowaniu VM-ów (pve9b z pve9, pve10 z pve9b). Lista sprzątania po klonie
obejmowała klucze HOSTA i klucze parowania, ale **nie** klucz użytkownika root.
Skutek: klucz dowolnego z tych trzech otwiera roota na pozostałych dwóch
wszędzie, gdzie ten klucz jest autoryzowany. Poza zakresem tego labu — do
decyzji właściciela.

### `deploy.sh` uruchomiony wprost nie czyta `grant-datasets`

Faza 8g padła na `rpool/data`/`rpool/ROOT/pve-1`, mimo że pve9 ma poprawny
`/root/.zfs-snapshot-all-update-state/grant-datasets` = `hdd` (zasiany przy
PR #292). Ten plik czyta **`update-control.sh`** i przekazuje go jako
`--grant-datasets=`; samo `deploy.sh` go nie zna. Wywołane ręcznie — a tak
robi każdy lab i każda naprawa z konsoli — wraca do twardego domyślnego i pada.
Naprawa #292 zamknęła ścieżkę automatyczną, nie ręczną.

## Rekomendacja: ZOSTAWIĆ i dopisać test, nie wycofywać

Krok 0 pokazuje komendę nieużywaną: zero śladów na siedmiu hostach, nic w
produkcie jej nie woła, a kierunek UX (`DEPLOY-UX-*`) świadomie odsuwa operatora
od ręcznego przenoszenia `.suggested`. To mocny argument za wycofaniem.

Mimo to rekomenduję **zostawić**, z jednego powodu opartego na pomiarze, nie na
sympatii: **ścieżka niskopoziomowa nie jest hipotetyczna — to ona jest w użyciu,
gdy wysokopoziomowa nie pasuje.** W trzech labach z ostatnich dwóch dni
schodziłem na ręczne `--pair` → wsad → `--join` → `--commit-scope`, bo
`--join-remotely` spadał na brak zaufania root↔root albo bo flagi nie było w
formie jednokomendowej. W każdym z tych przebiegów config składałem ręcznie —
czyli robiłem to, co ta komenda robi za mnie, tylko gorzej i bez listy
nieobjętych datasetów.

Komenda jest teraz **dowiedziona zachowaniem na żywo** (sześć własności), więc
argument „nietestowana" przestał obowiązywać. Co warto zrobić zamiast wycofania:

1. **naprawić błąd 1 w produkcie, nie tylko w runbooku** — `--draft-config` bez
   `--pair` powinno odmówić, a nie uruchamiać pełne wdrożenie hosta;
2. dopisać `test/draftscope` o przypadek „`--draft-config` bez `--pair`
   niczego nie wdraża";
3. rozstrzygnąć błąd 2 osobno: czy `update-hold` ma zatrzymywać także
   `deploy.sh` (dziś nie zatrzymuje, a drukuje że wstrzymane).

## Czego nie próbowano

- ostrzeżeń ze stderr o **braku** kopii klucza dla `--local-user` i o parowaniu
  bez przypiętego klucza hosta — oba parowania labu miały jedno i drugie;
- manifestu **bez** listy datasetów (`every candidate will be listed unfiltered`);
- portu innego niż 22 (czyli obecności `-p` we `flags`);
- roli `push` z **dokończonym** `--join` — wsad nie doszedł na pve9 (klucz roota
  pve10 nie jest tam autoryzowany), ale (E) tego nie potrzebuje: w roli push
  listowanie jest lokalne i draft powstał bez kontaktu z peerem. To samo w sobie
  jest obserwacją: **odmowa z (F) dotyczy wyłącznie roli `pull`**.

## Stan po labie

Oba hosty: `clean-relationships.sh` **rc=0**, pula `hdd` pusta, `peers/` puste,
`/root/scripts/pairing/` puste, `update-hold` zdjęty, oba na `4c00563b`.
Reszta floty stoi na `fcc5a26c` i dociągnie się sama cogodzinnym self-update.
