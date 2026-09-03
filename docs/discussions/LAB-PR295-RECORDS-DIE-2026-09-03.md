# Lab dla PR #295 — rekord to dane, `die` w `$( )`, reset stanu wywołania

Status: **WYKONANY 2026-09-03** — wynik w `LAB-PR295-WYNIK-2026-09-03.md`.
Spisany w sesji, która hostów nie widzi (port 22 do `192.168.28.x` i
`192.168.11.x` jest z niej nieosiągalny); poniżej wersja poprawiona o dwa
odstępstwa nazwane przez wykonawcę (ścieżka drzewa w kroku 1, brak rekordów
na flocie), żeby następny przebieg nie potykał się o to samo. Para z labu:
`pve9` 192.168.28.99 → `pve10` 192.168.28.97.

Gałąź: `claude/package-translation-estimate-jisaqu`, głowa `b0c7632`
(PR #295, CI 43/43 zielone). Punkt odniesienia: `main` `37ad17d`.

## Co lab ma dowieść

Dwa obowiązki ręczne z `./test/impact.sh origin/main..HEAD`:
`zfsbackup-live-pair` i `rux-live-chain`. Dla TEJ zmiany liczą się trzy
własności, których atrapy w suitach nie pokazują:

1. **Czytnik rekordów na prawdziwych plikach floty.** `record_get`/`record_load`
   (`lib-backup-common.sh`) zastąpiły `.`-sourcing rekordów relacji
   (`/etc/zfs-snapshot-all/clients/*.conf`, wartości `printf %q`, także z
   locale C crona), manifestów parowania (heredoc `deploy.sh`, wartości gołe,
   `"..."` i `'...'`) i markera pauzy. Suity używają fixture'ów pisanych
   ręcznie. **Ile rekordów ma flota, mierzy krok 0, nie zakłada runbook:**
   pierwszy przebieg zakładał „~20 na kolektor, część sprzed pól dodanych
   później" (zdanie z komentarza w kodzie, pisane dla starszego stanu floty),
   a pomiar dał ZERO na wszystkich siedmiu hostach — produkcja chodzi z
   `jobs.<host>.conf`. Bez rekordów krok 1b nie ma czego czytać, stąd
   kolejność: krok 3 (throwaway pair) PRZED 1b. Dowód: **każde polecenie
   tylko-do-odczytu daje bajt w bajt to samo wyjście na `main` i na gałęzi.**
2. **`die` w `$( )` kończy program.** Na żywych ścieżkach z ssh
   (`status NAZWA`, `verify-endpoint`, `activate-client`) pierwszy FATAL ma być
   ostatnią linią, a `status NAZWA` dla rekordu bez manifestu ma dalej
   raportować (jedyne miejsce z `die_confine_to_subshell`).
3. **Reaktywacja istniejącej relacji jest no-opem** — loader zwraca te same
   wartości co sourcing, więc wyrenderowany blok crona nie różni się od
   zainstalowanego.

Formaty na dysku są nietknięte, więc lab NIE wymaga nowego parowania, żeby
dowieść 1 i 3. Parowanie (krok 3) dowodzi 2 na ścieżce z ssh i domyka obowiązek
`zfsbackup-live-pair`.

## Zasady (z `docs/internal/IMPLEMENTER-ERROR-LOG.md`, sekcja 1)

- **Predykcje spisane PRZED biegiem** (R6): dla każdego kroku poniżej jest
  napisane, co ma wyjść. Wynik, który nie zgadza się z predykcją, kończy lab
  na tym kroku — nie „naprawiamy w locie".
- **Fakt jest prawdziwy po tej stronie granicy, po której go zmierzono** (R2):
  różnica `main` vs gałąź mierzona na tym samym hoście, w tej samej minucie,
  tym samym poleceniem.
- **Raport nazywa kształty, które przeszły, i te, których nie próbowano** (R12).

## Krok 0 — przygotowanie (oba hosty)

```bash
# jako root, na każdym hoście labu
S=/root/.zfs-snapshot-all-update-state
printf 'lab PR #295 %s\n' "$(date +%F)" > "$S/update-hold"     # cron co godzinę NIE ciągnie main
cd /root/scripts/zfs-snapshot-all
git fetch origin claude/package-translation-estimate-jisaqu
git worktree add /root/scripts/zfs-snapshot-all-pr295 b0c7632   # gałąź OBOK main, nie zamiast
ls /root/scripts/zfs-snapshot-all-pr295/lib-backup-common.sh    # kontrola: to jest to drzewo
# POMIAR, nie założenie: co jest na tym hoście do przeczytania
ls /etc/zfs-snapshot-all/clients/ /etc/zfs-snapshot-all/peers/ /var/lib/zfs-snapshot-all/relationships/ 2>&1
ls /etc/zfs-snapshot-all/jobs.*.conf
```

Jeśli `clients/` jest puste (stan całej floty 2026-09-03), krok 1 na tym
hoście dowodzi tylko ścieżki `jobs.*.conf`; rekord, manifest i marker pauzy
powstają dopiero w kroku 3 — wtedy wrócić do 1b.

Konto delegowane (`zfsbackup`) ma własny checkout w `$HOME/zfs-snapshot-all`
i własny cron `git pull` o :15 — to `update-hold` go nie dotyczy. Na czas labu
wystarczy nie dotykać tamtego checkoutu; krok 1 i 2 robimy jako root z
worktree PR-a. Jeśli krok 3 ma iść z konta delegowanego, wyciągnąć tam tę samą
głowę tak samo (`git worktree add` jako to konto).

Zapisać stan wyjściowy:

```bash
crontab -l > /root/lab295-crontab-root.before
su -s /bin/bash zfsbackup -c 'crontab -l' > /root/lab295-crontab-zfsbackup.before 2>/dev/null
tar -C / -czf /root/lab295-state.before.tgz etc/zfs-snapshot-all var/lib/zfs-snapshot-all 2>/dev/null
```

## Krok 1 — tylko-do-odczytu, `main` vs gałąź, bajt w bajt (jeden kolektor)

To jest krok, który przechodzi przez KAŻDY `record_load`/`record_get` na
prawdziwych danych, bez żadnej mutacji.

```bash
M=/root/scripts/zfs-snapshot-all          # main
B=/root/scripts/zfs-snapshot-all-pr295    # gałąź
CFG=$(ls /etc/zfs-snapshot-all/jobs.*.conf | head -1)   # albo wskazać właściwy jobs.<host>.<konto>.conf
run() {   # <drzewo> -> wyjście wszystkich poleceń read-only, stdout+stderr, z kodami wyjścia
    local T=$1
    { "$T/zfs-backup.sh" status;                            echo "rc=$?"
      for n in $(ls /etc/zfs-snapshot-all/clients/ | sed 's/\.conf$//'); do
          echo "=== status $n"; "$T/zfs-backup.sh" status "$n"; echo "rc=$?"
      done
      echo "=== audit-source-retention"; "$T/zfs-backup.sh" audit-source-retention; echo "rc=$?"
      echo "=== gen-cron -c";           "$T/gen-cron.sh" -c "$CFG";                 echo "rc=$?"
      echo "=== restore --plan";        "$T/zfs-restore.sh" --plan;                 echo "rc=$?"
      echo "=== clean-relationships";   "$T/clean-relationships.sh";                echo "rc=$?"
    } 2>&1
}
run "$M" > /root/lab295-ro-main.txt
run "$B" > /root/lab295-ro-branch.txt
diff /root/lab295-ro-main.txt /root/lab295-ro-branch.txt && echo IDENTYCZNE
```

**Predykcja:** `IDENTYCZNE`. Dopuszczalne różnice, obie nazwane w raporcie:

- **ścieżka drzewa**: `gen-cron.sh -c` wkleja w renderowane linie crona
  absolutną ścieżkę drzewa, z którego został wywołany, więc gałąź z worktree
  drukuje `…-pr295` (na pve0 96 linii, na pve2 22). Normalizować OBIE strony
  tą samą podstawianką i sprawdzić, że liczba linii po obu stronach jest równa
  — wtedy normalizacja nie może ukryć brakującego ani nadmiarowego wiersza:
  ```bash
  N='s#/root/scripts/zfs-snapshot-all-pr295#TREE#g; s#/root/scripts/zfs-snapshot-all#TREE#g'
  diff <(sed "$N" /root/lab295-ro-main.txt) <(sed "$N" /root/lab295-ro-branch.txt) && echo IDENTYCZNE
  wc -l /root/lab295-ro-main.txt /root/lab295-ro-branch.txt
  ```
- **znaczniki czasu**, jeśli któreś polecenie drukuje bieżący czas (powtórzyć
  obie strony i porównać z `grep -v` na tej jednej linii).

Jakakolwiek inna różnica — inna wartość pola, brakujący wiersz relacji,
dodatkowy FATAL, inny `rc` — **kończy lab**. To jest dokładnie ten wynik, po
który lab jest robiony.

Jeśli na hoście jest relacja spauzowana (`pause-client`), tym lepiej: `status`
czyta wtedy także marker pauzy przez `record_load pause`.

Powtórzyć krok 1 na drugim hoście floty, jeśli jest pod ręką (inny zestaw
rekordów, inne wieki pól).

## Krok 2 — reaktywacja no-op (ta sama relacja, ta sama gałąź)

```bash
n=<nazwa istniejącej AKTYWNEJ relacji z kroku 1>
crontab -l > /root/lab295-crontab.step2.before
"$B/zfs-backup.sh" activate-client "$n" --yes 2>&1 | tee /root/lab295-step2.txt; echo "rc=$?"
crontab -l | diff /root/lab295-crontab.step2.before - && echo CRONTAB-BEZ-ZMIAN
```

**Predykcja:** komunikat o braku zmian (blok identyczny z zainstalowanym),
`rc=0`, `CRONTAB-BEZ-ZMIAN`. Reaktywacja czyta rekord, manifest i zainstalowany
CONFIG przez nowy czytnik i renderuje z nich — jedyny sposób, żeby wyszło coś
innego niż no-op, to inna wartość jakiegoś pola.

Jeśli relacja jest uruchamiana z konta delegowanego, porównać crontab TEGO
konta, nie roota.

## Krok 3 — throwaway pair (dowodzi `die` na ścieżce ssh i domyka `zfsbackup-live-pair`)

Datasety wyłącznie jednorazowe (`hdd/lab295src` na źródle, cel pod
`hdd/backups`), jak w labie 2026-09-03. Kolejność jak w README, z jednego
drzewa (`$B` na obu hostach):

```bash
# kolektor (pve9)
"$B/zfs-backup.sh" add-client lab295 --host=192.168.28.97:22 --target=hdd/backups --datasets=hdd/lab295src
# źródło (pve10): join pakietu, jak zwykle
# kolektor
"$B/zfs-backup.sh" seed lab295
```

Po `seed` (rekord w stanie `seed_complete`) — **test własności 2**, zanim
cokolwiek zostanie zainstalowane:

```bash
cp /etc/zfs-snapshot-all/clients/lab295.conf /root/lab295-record.before
"$B/zfs-backup.sh" set-endpoint lab295 --host='bad host' 2>&1 | tee /root/lab295-step3-die.txt; echo "rc=$?"
grep -c '^FATAL:' /root/lab295-step3-die.txt
diff /root/lab295-record.before /etc/zfs-snapshot-all/clients/lab295.conf && echo REKORD-NIETKNIETY
"$B/zfs-backup.sh" status lab295; echo "rc=$?"
```

**Predykcja:** dokładnie **1** linia `FATAL:` (`invalid endpoint host`), `rc=1`,
`REKORD-NIETKNIETY`, brak linii `refusing to switch`. Na `main` tym samym
poleceniem: **2** linie FATAL (druga to `refusing to switch ... no final
catch-up`), bo pierwszy `die` kończył tylko podpowłokę i program szedł dalej.
`status lab295` po tym: `rc=0`, widok kompletny.

Kontrola ujemna na żywo, jeśli czas pozwala: to samo `set-endpoint` z `$M` —
oczekiwane 2 FATAL. Bez tej kontroli punkt „na main 2 FATAL" opiera się
wyłącznie na suicie, i tak ma być napisane w raporcie.

Dalej normalnie:

```bash
"$B/zfs-backup.sh" activate lab295
"$B/zfs-backup.sh" status lab295                 # STATE=active, endpoint, blok crona
"$B/zfs-backup.sh" test lab295                   # jeśli dostępne w tej wersji: jedno przejście
```

**Predykcja:** przebieg jak w labie 2026-09-03; `activate` instaluje blok
transakcyjnie, `status` pokazuje `active`. Żadnej różnicy względem tamtego
labu, bo ani parowanie, ani ssh, ani render crona nie zmieniły się w tym PR.

## Krok 4 (opcjonalny) — `rux-live-chain`

Forma jednokomendowa na tej samej parze, po rozbiórce kroku 3:

```bash
"$B/zfs-backup.sh" --source=192.168.28.97:hdd/lab295src --target=hdd/backups --plan
"$B/zfs-backup.sh" --source=192.168.28.97:hdd/lab295src --target=hdd/backups --install --yes
```

`rux_resolve_name`, `rux_check_conflict`, `rux_verify_requested_scope` czytają
rekordy przez `record_load` z polami `local` — to ścieżka, dla której czytnik
zeruje pustym łańcuchem zamiast `unset` (patrz komentarz w
`lib-backup-common.sh`). **Predykcja:** `--plan` nazywa relację i stan, `--install`
zakłada ją i aktywuje jak w labie 2026-08-16 (dwa dowody dwuhostowe).

## Rozbiórka (obowiązkowa, do zera)

```bash
# kolektor
"$B/zfs-backup.sh" remove-client lab295
# źródło
"$B/deploy.sh" --leave=<etykieta z komunikatu remove-client>
# oba: datasety labu skasować ręcznie (nie robi tego żadne narzędzie — decyzja właściciela)
# oba: audyt śladów
"$B/clean-relationships.sh"            # ma być czysto; --purge-orphans tylko po przeczytaniu listy
# oba: crontab wrócony
crontab -l | diff /root/lab295-crontab-root.before - && echo CRONTAB-ROOT-OK
# oba: klony z powrotem, aktualizacje wznowione
git -C /root/scripts/zfs-snapshot-all worktree remove /root/scripts/zfs-snapshot-all-pr295
/root/.zfs-snapshot-all-update-state/update-control.sh --resume-updates   # albo: deploy.sh --resume-updates
```

## Co przekazać z powrotem (do odpowiedzi w PR #295 / `PROJECT_STATUS.md`)

Tabela: krok | host(y) | polecenie | predykcja | wynik | plik z transkryptem.
Osobno: **czego NIE próbowano** (np. brak relacji spauzowanej na hoście → marker
pauzy nieprzetestowany na żywo; brak kontroli ujemnej w kroku 3 → punkt o
2 FATAL na `main` z suity, nie z hosta). Wyniki `diff` z kroku 1 wkleić
dosłownie, także gdy puste.

Warunki stopu, jeszcze raz: niepusty `diff` w kroku 1, zmiana crontaba w
kroku 2, więcej niż jedna linia FATAL albo zmieniony rekord w kroku 3.
Każdy z nich to defekt PR #295 do zgłoszenia, nie do obejścia na hoście.
