# Lab — skrypty hostów jako pliki w checkoucie (`hostscripts/`), nie heredoki

Status: **DO WYKONANIA** przez wątek z dostępem do floty. Spisany w sesji,
która hostów nie widzi. Wynik proszę spisać do `LAB-HOSTSCRIPTS-WYNIK-2026-09-03.md`
tym samym układem co `LAB-PR295-WYNIK-2026-09-03.md`.

Gałąź: `claude/package-translation-estimate-jisaqu` (PR z tego runbooka; głowa
w opisie PR). Punkt odniesienia: `main` w chwili startu labu.

## Co się zmieniło i co lab ma dowieść

Do tej pory `notify-fail.sh`, `notify-warn.sh`, `alert-digest.sh` i
`check-pool-capacity.sh` powstawały z niecytowanych heredoków w `deploy.sh`
(~1350 linii, każdy runtime'owy `$` pisany `\$`, backtick w KOMENTARZU
wykonywał polecenie jako root przy instalacji — REV-20260902-133), a
„aktualny" znaczyło „marker wersji zgadza się", co człowiek musiał pamiętać
bumpnąć. Teraz są plikami w `hostscripts/` (plus `alert-env.sh` — wspólna
preambuła config/env, dotąd zmienna `ALERT_ENV_PREAMBLE` wklejana w trzy
skrypty), a `deploy.sh` je **kopiuje**: aktualny = bajt w bajt jak w
checkoucie i wykonywalny. Nic się nie rozwija, nic nie trzeba bumpować.

Trzy własności, których suity nie pokazują, bo wymagają roota i prawdziwego
`/root/scripts`:

1. **Pierwsze wdrożenie z gałęzi podmienia cztery skrypty i dokłada piąty.**
   `--check-only` przed: cztery „present but not the checkout's copy",
   `alert-env.sh missing`. Zwykły przebieg: pięć „installed … from
   hostscripts/". Drugi przebieg: pięć „already current".
2. **Zainstalowane pliki działają jak poprzednie.** Digest i notify czytają
   `/etc/zfs-alert.conf` przez `alert-env.sh` obok siebie (root:
   `/root/scripts`, konto: `$HOME`), ten sam adres, ta sama kolejka.
3. **Rollback na `main` wraca do heredoków.** Stary `deploy.sh` grep-uje
   marker (`# alert-digest.sh v36`), nowy plik ma `v37` → stary `deploy.sh`
   uznaje go za nieaktualny i nadpisuje swoją wersją. `alert-env.sh` zostaje
   jako nieużywany plik (nieszkodliwy; do skasowania ręcznie).

## Kroki

Host do labu: jeden kolektor z kontem delegowanym (np. `pve9`), żeby
przećwiczyć obie gałęzie (root + konto). Wszystko poniżej jako root.

### 0. Stan przed

```
cd /root/scripts/zfs-snapshot-all
git rev-parse --short HEAD                      # main przed labem
for f in notify-fail notify-warn alert-digest check-pool-capacity; do
  sed -n 2p /root/scripts/$f.sh; done            # markery: v9 / v7 / v36 / v6
ls -l /root/scripts/alert-env.sh 2>&1           # oczekiwane: brak
ls -l /home/*/notify-fail.sh /home/*/alert-env.sh 2>&1
grep -c . /var/lib/zfs-snapshot-all/alerts/alert-queue.log 2>/dev/null || true  # dlugosc kolejki
cp -a /root/scripts/alert-digest.sh /root/alert-digest.sh.before-lab
```

### 1. Audyt z gałęzi, zanim cokolwiek się zmieni

```
git fetch origin claude/package-translation-estimate-jisaqu
git checkout --detach origin/claude/package-translation-estimate-jisaqu
ls hostscripts/                                 # 5 plikow
bash deploy.sh --check-only 2>&1 | grep -E 'alert-env|notify-fail|notify-warn|alert-digest|check-pool-capacity'
```

Oczekiwane: `alert-env.sh missing`, cztery `present but not the checkout's
copy (...)`, dla konta `/home/<konto>/alert-env.sh missing`. **Nic nie zostało
zapisane** (`ls -l /root/scripts/*.sh` — mtime bez zmian).

### 2. Wdrożenie

```
bash deploy.sh 2>&1 | grep -E 'hostscripts|already current|alert-env|notify-fail|notify-warn|alert-digest|check-pool-capacity'
for f in alert-env notify-fail notify-warn alert-digest check-pool-capacity; do
  cmp hostscripts/$f.sh /root/scripts/$f.sh && echo "SAME $f"; done
ls -l /root/scripts/alert-env.sh                 # -rw-r--r-- root
ls -l /home/*/alert-env.sh /home/*/notify-fail.sh /home/*/notify-warn.sh
bash deploy.sh --check-only 2>&1 | grep -cE 'present \(current\)'   # >= 5 (4 root + alert-env; konto osobno)
bash deploy.sh 2>&1 | grep -c 'already current, leaving it alone'   # 5
```

### 3. Skrypty działają

```
# notify-fail jako root, na KOPII kolejki -- srodowisko bije config:
ZFS_ALERT_MODE=daily ZFS_ALERT_QUEUE=/tmp/lab-q ZFS_ALERT_STATE_DIR=/tmp/lab-st \
  /root/scripts/notify-fail.sh "lab job" "lab detail"; echo rc=$?; cat /tmp/lab-q
# to samo z konta:
su <konto> -s /bin/bash -c 'ZFS_ALERT_MODE=daily ZFS_ALERT_QUEUE=/tmp/lab-q2 ZFS_ALERT_STATE_DIR=/tmp/lab-st2 $HOME/notify-fail.sh "lab job" "lab detail"; echo rc=$?; cat /tmp/lab-q2'
# digest na kopii prawdziwej kolejki, mail stubowany:
cp /var/lib/zfs-snapshot-all/alerts/alert-queue.log /tmp/lab-queue 2>/dev/null || : > /tmp/lab-queue
mkdir -p /tmp/lab-bin; printf '#!/bin/sh\ncat > /tmp/lab-mail.txt\n' > /tmp/lab-bin/mail; chmod +x /tmp/lab-bin/mail
PATH=/tmp/lab-bin:$PATH ZFS_ALERT_QUEUE=/tmp/lab-queue ZFS_DIGEST_QUIET=daily /root/scripts/alert-digest.sh; echo rc=$?
head -20 /tmp/lab-mail.txt                       # naglowek i tabela jak w ostatnim prawdziwym digescie
# brak alert-env.sh obok = glosna odmowa, nie cichy default:
mkdir -p /tmp/lab-alone; cp /root/scripts/notify-fail.sh /tmp/lab-alone/
/tmp/lab-alone/notify-fail.sh x y; echo rc=$?     # "cannot source alert-env.sh next to this script", rc=1
```

Porównanie z „przed": `diff <(sed 1,2d /root/alert-digest.sh.before-lab) <(sed 1,2d /root/scripts/alert-digest.sh)`
— oczekiwane różnice TYLKO: blok preambuły → jedna linia `. "$(dirname "$0")/alert-env.sh" …`,
oraz `${ZFS_ALERT_EMAIL:-<adres>}` → `${ZFS_ALERT_EMAIL:-root}`. Nic więcej.

### 4. Rollback i powrót

```
git checkout --detach <main-sprzed-labu>
bash deploy.sh 2>&1 | grep -E 'notify-fail|notify-warn|alert-digest|check-pool-capacity'   # cztery "upgrading" ze starych heredokow
sed -n 2p /root/scripts/alert-digest.sh          # v36 z powrotem
git checkout main && git pull --ff-only          # albo zostac na galezi do scalenia
```

Po scaleniu PR godzinny `update-control.sh` wdroży to samo na resztę floty
(po fast-forwardzie uruchamia `deploy.sh`); sprawdzić następnego dnia
`grep -l 'hostscripts' /root/scripts/cron.log` lub `sed -n 2p /root/scripts/alert-digest.sh`
na każdym hoście: `v37`.

## Co zapisać w wyniku

- SHA gałęzi i `main`, host, konto;
- pełne wyjście kroku 1 (`--check-only` przed) i kroku 2 (pięć `installed`,
  potem pięć `already current`);
- wynik `cmp` dla pięciu plików;
- rc i zawartość `/tmp/lab-q`, `/tmp/lab-q2`, pierwsze 20 linii `/tmp/lab-mail.txt`;
- wynik odmowy bez `alert-env.sh`;
- `diff` z kroku 3 (tylko dwie klasy różnic);
- krok 4: czy stary `deploy.sh` nadpisał pliki (markery wróciły).

Sprzątanie: `rm -rf /tmp/lab-*`, `rm /root/alert-digest.sh.before-lab`.
