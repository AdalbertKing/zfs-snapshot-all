# Lab: postawienie łańcucha i sprawdzenie go — komendy

Dokładnie to, co uruchomiłem 2026-08-20 na metropolis, w kolejności, razem
z miejscami, w których narzędzie się **zatrzymuje i czeka na człowieka**.

Łańcuch: `pve9 (192.168.28.99) → pve2 (192.168.28.8) → pve1 (192.168.28.9)`.

Konwencja niżej: `[pve9]` znaczy „uruchom to na tym hoście".

---

## 0. Rozpoznanie — zanim cokolwiek ruszysz

```bash
[każdy host]  zpool list
              git -C /root/scripts/zfs-snapshot-all rev-parse --short HEAD
              ls -A /etc/zfs-snapshot-all/
              ls -A /etc/zfs-snapshot-all/clients/
              grep -cE '^[0-9*]' /var/spool/cron/crontabs/*
```

Czego szukasz: czy hosty są na tej samej rewizji, czy nie ma pozostałości po
poprzednim labie (`clients/*.conf` ze `STATE=removed`, pliki `.zfsbackup-work.*`,
manifesty w `peers/`).

**Pozostałości blokują.** U mnie zablokowały dwa razy — patrz krok 3.

## 1. Dane źródłowe

```bash
[pve9]  zfs create -p hdd/lab4/src
        dd if=/dev/urandom of=/hdd/lab4/src/plik1.bin bs=1M count=8 status=none
        dd if=/dev/urandom of=/hdd/lab4/src/plik2.bin bs=1M count=4 status=none
        sync
        md5sum /hdd/lab4/src/*.bin      # ZAPISZ TE SUMY — to punkt odniesienia
```

## 2. Plan — nie dotyka żadnego hosta

```bash
[pve2]  cd /root/scripts/zfs-snapshot-all
        bash zfs-backup.sh --source=192.168.28.99:hdd/lab4/src \
                           --target=hdd/lab4backups
```

Bez `--install` to czysty odczyt. Pokazuje nazwę relacji, tryb, etapy.
**Przeczytaj i dopiero potem instaluj.**

## 3. Instalacja — zatrzyma się na grancie

```bash
[pve2]  bash zfs-backup.sh --source=192.168.28.99:hdd/lab4/src \
                           --target=hdd/lab4backups --install --yes
```

Kończy się `FATAL: the source ... has GRANTED nothing yet`. **To nie jest błąd.**
Przyznanie zakresu jest decyzją strony źródłowej i nigdy nie wykonuje się zdalnie.

Zanim przyznasz — **obejrzyj, co ma zostać przyznane**:

```bash
[pve9]  cat /etc/zfs-snapshot-all/peers/pve2.scope
```

Szukasz sekcji `[dataset:...]`. Ma tam być **tylko** to, co backupujesz.
Jeśli widzisz cokolwiek produkcyjnego — nie przyznawaj.

```bash
[pve9]  cd /root/scripts/zfs-snapshot-all
        bash deploy.sh --commit-scope=pve2
```

Potem **powtórz dokładnie tę samą komendę** z kroku 3 na pve2. Wznowi.

## 4. Drugi skok — to samo, w drugą stronę

```bash
[pve1]  cd /root/scripts/zfs-snapshot-all
        bash zfs-backup.sh --source=192.168.28.8:hdd/lab4backups/192.168.28.99/hdd/lab4/src \
                           --target=hdd/lab4chain --name=lab4-pve2 --install --yes
```

`--name=` jest tu **konieczne**, jeśli host miał już kiedyś relację z tym peerem
i została usunięta: stan `removed` jest terminalny i domyślna nazwa się o niego
rozbije.

Gdy zdalny join nie przejdzie automatycznie, narzędzie wypisze wsad i dwie
komendy. Wtedy:

```bash
[pve1]  scp /root/scripts/pairing/pve1-to-192.168.28.8.tgz root@192.168.28.8:/root/
[pve2]  cd /root/scripts/zfs-snapshot-all
        bash deploy.sh --join=/root/pve1-to-192.168.28.8.tgz
```

`--join` **pyta o akceptację zakresu i nie ma żadnego `--yes`** — to celowe,
przyjęcie zakresu jest decyzją bezpieczeństwa. Przeczytaj wypisany
`[dataset:...]`, potem odpowiedz `t`.

Potem znowu: **powtórz komendę z początku kroku 4 na pve1**.

## 5. Weryfikacja — czy dane naprawdę doszły

**Nigdy nie montuj datasetu-kopii.** Odebrane datasety nie są montowane
i montowanie ich psuje wykrywanie rozbieżności. Użyj klonu:

```bash
[kolektor]  S=$(zfs list -H -t snapshot -o name -s creation -r <cel> | tail -1)
            zfs clone -o mountpoint=/mnt/check "$S" <pool>/check
            md5sum /mnt/check/*.bin        # porównaj z krokiem 1
            zfs destroy <pool>/check
```

## 6. Weryfikacja — czy lab nie tknął produkcji

```bash
[kolektor]  # 1. granty tylko na liściach laba, zero na produkcji
            for d in hdd/vm-disks hdd/backups rpool/data rpool/ROOT; do
                echo "$d -> $(zfs allow $d 2>/dev/null | grep -c zfsbackup-)"
            done
            # 2. produkcyjny crontab nietknięty
            grep -cE '^[0-9*]' /var/spool/cron/crontabs/zfsbackup
            grep -o 'Source: [^ ]*' /var/spool/cron/crontabs/zfsbackup
            # 3. blok laba osobno
            grep -o 'Source: [^ ]*' /var/spool/cron/crontabs/root
```

Zadania laba idą do crontaba **roota** i osobnego configu (`jobs.<host>.conf`),
produkcja zostaje na koncie `zfsbackup` i swoim configu (`jobs.<host>.v4.conf`).
Konta labowe nazywają się `zfsbackup-<peer>` — jeśli któreś pojawi się w wyniku
punktu 1, coś jest nie tak.

## Zatrzymania, które są POPRAWNE

| komunikat | co znaczy |
|---|---|
| `has GRANTED nothing yet` | grant to ruch strony źródłowej, zrób krok 3 |
| `manifest ... already exists with a DIFFERENT account/target` | pozostałość po starym labie, obejrzyj i odsuń |
| `join interrupted before scope acceptance` | `--join` czeka na `t`, nie ma `--yes` |
| `unknown state 'removed'` (przed poprawką) | relacja usunięta, użyj `--name=NOWA` |

## Sprzątanie po labie

```bash
[pve2]  zfs destroy -r hdd/lab4backups
[pve1]  zfs destroy -r hdd/lab4chain
[pve9]  zfs destroy -r hdd/lab4
[każdy] bash zfs-backup.sh remove-client <nazwa>
```

Odsunięte pozostałości po lab3 leżą na pve2 w `/root/lab3-residue.<timestamp>/`
— nie skasowane, na wypadek gdyby czegoś zabrakło.
